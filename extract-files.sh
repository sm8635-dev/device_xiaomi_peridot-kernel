#!/bin/bash

set -e

# Simple color
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

EXTRACT_OTA=../../../prebuilts/extract-tools/linux-x86/bin/ota_extractor
MKDTBOIMG=../../../system/libufdt/utils/src/mkdtboimg.py
UNPACKBOOTIMG=../../../system/tools/mkbootimg/unpack_bootimg.py
ROM_ZIP=$1

declare -a DTBO_PANEL_PATCHES=(
    "Peridot:dsi_n16t_36_0f_0b_dsc_vid"
    "Peridot:dsi_n16t_42_02_0a_dsc_vid"
    "Peridot:dsi_n16t_42_0a_0c_dsc_vid"
)

error_handler() {
    if [[ -d $extract_out ]]; then
        echo -e "${RED}Error detected, cleaning temporal working directory $extract_out${NC}"
        rm -rf $extract_out
    fi
}

trap error_handler ERR

function usage() {
    echo -e "${RED}Usage: ./extract-files.sh <rom-zip>${NC}"
    exit 1
}

function get_path() {
    echo "$extract_out/$1"
}

function mkdtboimg() {
    $MKDTBOIMG $@
}

function unpackbootimg() {
    $UNPACKBOOTIMG $@
}

function extract_ota() {
    $EXTRACT_OTA $@
}

if [[ ! -f $UNPACKBOOTIMG ]]; then
    echo -e "${RED}Missing $UNPACKBOOTIMG, are you on the correct directory?${NC}"
    exit 1
fi

if [[ ! -f $EXTRACT_OTA ]]; then
    echo -e "${RED}Missing $EXTRACT_OTA, are you on the correct directory and have built the ota_extractor target?${NC}"
    exit 1
fi

if [[ -z $ROM_ZIP ]] || [[ ! -f $ROM_ZIP ]]; then
    usage
fi

# Clean and create needed directories
echo -e "${BLUE}Preparing directories...${NC}"
for dir in ./modules/vendor_dlkm ./modules/system_dlkm ./modules/vendor_boot ./images ./images/dtbs; do
    rm -rf $dir
    mkdir -p $dir
done

# Extract the OTA package
extract_out=$(mktemp -d)
echo -e "${BLUE}Using $extract_out as working directory${NC}"

echo -e "${BLUE}Extracting the payload from $ROM_ZIP${NC}"
unzip $ROM_ZIP payload.bin -d $extract_out

echo -e "${BLUE}Extracting OTA images${NC}"
extract_ota -payload $extract_out/payload.bin -output_dir $extract_out -partitions boot,dtbo,vendor_boot,vendor_dlkm,system_dlkm

# BOOT
echo -e "${BLUE}Extracting the kernel image from boot.img${NC}"
out=$extract_out/boot-out
mkdir $out

echo -e "${BLUE}Extracting at $out${NC}"
unpackbootimg --boot_img $(get_path boot.img) --out $out --format mkbootimg

echo -e "${GREEN}Done. Copying the kernel${NC}"
cp $out/kernel ./images/kernel
echo -e "${GREEN}Done${NC}"

# VENDOR_BOOT
echo -e "${BLUE}Extracting the ramdisk kernel modules and DTB${NC}"
out=$extract_out/vendor_boot-out
mkdir $out

echo -e "${BLUE}Extracting at $out${NC}"
unpackbootimg --boot_img $(get_path vendor_boot.img) --out $out --format mkbootimg

echo -e "${GREEN}Done. Extracting the ramdisk${NC}"
mkdir $out/ramdisk
unlz4 $out/vendor_ramdisk00 $out/vendor_ramdisk
cpio -i -F $out/vendor_ramdisk -D $out/ramdisk

echo -e "${BLUE}Copying all ramdisk modules${NC}"
for module in $(find $out/ramdisk -name "*.ko" -o -name "modules.load*" -o -name "modules.blocklist"); do
    cp $module ./modules/vendor_boot/
done

# VENDOR_DLKM
echo -e "${BLUE}Extracting the dlkm kernel modules${NC}"
out=$extract_out/vendor_dlkm

echo -e "${BLUE}Extracting at $out${NC}"
fsck.erofs --extract="$out" $(get_path vendor_dlkm.img)

echo -e "${GREEN}Done. Extracting the vendor dlkm${NC}"

echo -e "${BLUE}Copying all vendor dlkm modules${NC}"
for module in $(find $out/lib -name "*.ko" -o -name "modules.load*" -o -name "modules.blocklist"); do
    cp $module ./modules/vendor_dlkm/
done

# SYSTEM_DLKM
echo -e "${BLUE}Extracting the dlkm kernel modules${NC}"
out=$extract_out/system_dlkm

echo -e "${BLUE}Extracting at $out${NC}"
fsck.erofs --extract="$out" $(get_path system_dlkm.img)

echo -e "${GREEN}Done. Extracting the system dlkm${NC}"

echo -e "${BLUE}Copying all system dlkm modules${NC}"
cp -r $out/lib/modules/6.1* ./modules/system_dlkm/

# Extract DTBO and DTBs
echo -e "${BLUE}Extracting DTBO and DTBs${NC}"

curl -sSL "https://raw.githubusercontent.com/PabloCastellano/extract-dtb/master/extract_dtb/extract_dtb.py" > ${extract_out}/extract_dtb.py

# Copy DTB
python3 "${extract_out}/extract_dtb.py" "${extract_out}/vendor_boot-out/dtb" -o "${extract_out}/dtbs" > /dev/null
find "${extract_out}/dtbs" -type f -name "*.dtb" \
    -exec cp {} ./images/dtbs/ \; \
    -exec printf "${GREEN}  - dtbs/" \; \
    -exec basename {} \;

python3 "${extract_out}/extract_dtb.py" "${extract_out}/dtbo.img" -o "${extract_out}/dtbo" > /dev/null
for DTBO_PANEL_PATCH in "${DTBO_PANEL_PATCHES[@]}"; do
    DTBO_PANEL_PATCH=(${DTBO_PANEL_PATCH//:/ })
    device=${DTBO_PANEL_PATCH[0]}
    panel=${DTBO_PANEL_PATCH[1]}
    find "${extract_out}/dtbo" -type f -name "*${device}*.dtb" -exec grep -q "${panel}" {} \; \
        -exec bash -c '
            dt_node="$(fdtget -t s "{}" /__symbols__ "'${panel}'")";
            fdtput -t i "{}" "$dt_node" qcom,dsi-supported-dfps-list 60 120 90;
        ' \; \
        -exec printf "${YELLOW}    + Fixed up removed 30hz of ${panel} in dtbo/" \; \
        -exec basename {} \;
done
mkdtboimg \
    create "./images/dtbo.img" --page_size=4096 "${extract_out}/dtbo/"*.dtb
echo -e "${YELLOW}    + Generated images/dtbo.img${NC}"

# Add touch modules to vendorboot for recovery
echo -e "${BLUE}Adding touch modules to vendorboot for recovery${NC}"
for module in xiaomi_touch.ko goodix_core.ko focaltech_touch.ko; do
    cp modules/vendor_dlkm/$module modules/vendor_boot/
    echo $module >> modules/vendor_boot/modules.load.recovery
done

rm -rf $extract_out
echo -e "${GREEN}Extracted files successfully${NC}"
