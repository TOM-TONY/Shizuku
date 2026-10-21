#!/bin/sh
set -eu

swift_configuration=debug
if [ "${CONFIGURATION}" = "Release" ]; then
    swift_configuration=release
fi

# SHIZUKU_SWIFT_TOOLCHAIN optionally selects the toolchain for the nested SwiftPM builds.
build_core_product() (
    # The nested SwiftPM build selects its own macOS SDK and toolchain.
    unset SDKROOT TOOLCHAIN_DIR DT_TOOLCHAIN_DIR TOOLCHAINS
    if [ -n "${SHIZUKU_SWIFT_TOOLCHAIN:-}" ]; then
        swift build --toolchain "${SHIZUKU_SWIFT_TOOLCHAIN}" --package-path "${SRCROOT}/Core" --product "$1" -c "${swift_configuration}"
    else
        swift build --package-path "${SRCROOT}/Core" --product "$1" -c "${swift_configuration}"
    fi
)

build_core_product ConverterServer

server_source="${SRCROOT}/Core/.build/${swift_configuration}/ConverterServer"
server_directory="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers/Shizuku.app"
server_compatibility_path="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers/ConverterServer"
server_destination="${server_directory}/ConverterServer"
server_build_directory="${SRCROOT}/Core/.build/${swift_configuration}"
# Keep the existing launch path while packaging a named, signed helper bundle.
if [ -d "${server_compatibility_path}" ] && [ ! -L "${server_compatibility_path}" ] && [ ! -e "${server_directory}" ]; then
    mv "${server_compatibility_path}" "${server_directory}"
fi
mkdir -p "${server_directory}"
if [ -L "${server_compatibility_path}" ]; then
    if [ "$(readlink "${server_compatibility_path}")" != "Shizuku.app" ]; then
        echo "Unexpected ConverterServer compatibility link" >&2
        exit 1
    fi
elif [ -e "${server_compatibility_path}" ]; then
    echo "Conflicting ConverterServer helper directory" >&2
    exit 1
else
    ln -s "Shizuku.app" "${server_compatibility_path}"
fi
cp "${server_source}" "${server_destination}"
# App metadata gives the helper the product name in macOS privacy indicators.
cp "${SRCROOT}/Core/Sources/ConverterServer/Info.plist" "${server_directory}/Info.plist"

# SwiftPM の Bundle.module は、実行時に Bundle.main.bundleURL 直下を最初に探し、
# 見つからない場合はビルド時の絶対パスへフォールバックする。Helperを独立した
# Contents/Helpers配下のdirectoryに置くと、そのdirectoryがBundle.mainになるため、
# resource bundleも同じ場所に置ける。app bundle root直下はcodesignで許可されない。
for resource_bundle in "${server_build_directory}"/*.bundle; do
    if [ -d "${resource_bundle}" ]; then
        resource_bundle_name="$(basename "${resource_bundle}")"
        embedded_resource_bundle="${server_directory}/${resource_bundle_name}"
        ditto "${resource_bundle}" "${embedded_resource_bundle}"
        # command-line SwiftPM buildが生成するbundleはInfo.plistを持たないため、
        # archiveのcodesignが正規のresource bundleとして検証できるよう補う。
        # llm-ime: Xcode 27 の SwiftPM は Contents/ 構造の bundle を生成する。その場合に
        # bundle 直下へ Info.plist を置くと codesign が "unsealed contents" で失敗するため、
        # Contents/Info.plist が無いときだけ Contents/ 内に補う。
        if [ -d "${embedded_resource_bundle}/Contents" ]; then
            if [ ! -f "${embedded_resource_bundle}/Contents/Info.plist" ]; then
                cp "${SRCROOT}/Tools/ConverterServerResourceBundleInfo.plist" "${embedded_resource_bundle}/Contents/Info.plist"
            fi
        else
            cp "${SRCROOT}/Tools/ConverterServerResourceBundleInfo.plist" "${embedded_resource_bundle}/Info.plist"
        fi
    fi
done

if ! otool -l "${server_destination}" | grep -q "@executable_path/../../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../../Frameworks" "${server_destination}"
fi

if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]; then
    for resource_bundle in "${server_directory}"/*.bundle; do
        if [ -d "${resource_bundle}" ]; then
            codesign \
                --force \
                --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
                --timestamp=none \
                "${resource_bundle}"
            codesign --verify --strict "${resource_bundle}"
        fi
    done
    server_identifier="${PRODUCT_BUNDLE_IDENTIFIER}.ConverterServer"
    # ConverterServerも学習データや個人化モデルをApp Groupから読む。entitlementなしで
    # Group Containersを直接参照すると、macOSが「ほかのアプリのデータ」と判定して
    # ファイルごとのアクセス確認を表示するため、埋め込みHelperにも同じGroupを付与する。
    codesign \
        --force \
        --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
        --identifier "${server_identifier}" \
        --options runtime \
        --entitlements "${SRCROOT}/Shizuku/ConverterServer.entitlements" \
        --timestamp=none \
        "${server_directory}"
    codesign --verify --strict "${server_directory}"
fi

# llm-ime: 解析と学習（ShizukuLab）。ConverterServer が必要なときだけ起動する別のプロセス。サンドボックスで動かし、ネットワークは使えない
build_core_product ShizukuLab
lab_directory="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers/ShizukuLab"
lab_destination="${lab_directory}/ShizukuLab"
mkdir -p "${lab_directory}"
cp "${server_build_directory}/ShizukuLab" "${lab_destination}"
for resource_bundle in "${server_build_directory}"/*.bundle; do
    if [ -d "${resource_bundle}" ]; then
        resource_bundle_name="$(basename "${resource_bundle}")"
        ditto "${server_directory}/${resource_bundle_name}" "${lab_directory}/${resource_bundle_name}"
    fi
done
if ! otool -l "${lab_destination}" | grep -q "@executable_path/../../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../../Frameworks" "${lab_destination}"
fi
if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]; then
    for resource_bundle in "${lab_directory}"/*.bundle; do
        if [ -d "${resource_bundle}" ]; then
            codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --timestamp=none "${resource_bundle}"
        fi
    done
    codesign \
        --force \
        --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
        --identifier "${PRODUCT_BUNDLE_IDENTIFIER}.ShizukuLab" \
        --options runtime \
        --entitlements "${SRCROOT}/Shizuku/ShizukuLab.entitlements" \
        --timestamp=none \
        "${lab_destination}"
    codesign --verify --strict "${lab_destination}"
fi
