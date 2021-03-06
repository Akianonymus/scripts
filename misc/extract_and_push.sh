#!/usr/bin/env bash

curl --fail --silent --location https://git.rip -o /dev/null || exit 1

[[ -z ${API_KEY} ]] && echo "API_KEY not defined, exiting!" && exit 1

CHAT_ID="-1001412293127"

# usage: normal - sendTg normal "message to send"
#        reply  - sendTg reply message_id "reply to send"
#        edit   - sendTg edit message_id "new message" ( new message must be different )
sendTG() {
    local mode="${1:?Error: Missing mode}" && shift
    local api_url="https://api.telegram.org/bot${API_KEY:?}"
    if [[ ${mode} =~ normal ]]; then
        curl -s "${api_url}/sendmessage" --data "text=${*:?Error: Missing message text.}&chat_id=${CHAT_ID:?}&parse_mode=HTML"
    elif [[ ${mode} =~ reply ]]; then
        local message_id="${1:?Error: Missing message id for reply.}" && shift
        curl -s "${api_url}/sendmessage" --data "text=${*:?Error: Missing message text.}&chat_id=${CHAT_ID:?}&parse_mode=HTML&reply_to_message_id=${message_id}"
    elif [[ ${mode} =~ edit ]]; then
        local message_id="${1:?Error: Missing message id for edit.}" && shift
        curl -s "${api_url}/editMessageText" --data "text=${*:?Error: Missing message text.}&chat_id=${CHAT_ID:?}&parse_mode=HTML&message_id=${message_id}"
    fi
}

[[ -z $ORG ]] && ORG="dumps"

if [[ -f $URL ]]; then
    cp -v "$URL" .
    MESSAGE="<code>Found file locally.</code>"
    if _json="$(sendTG normal "${MESSAGE}")"; then
        # grab initial message id
        MESSAGE_ID="$(jq ".result.message_id" <<< "${_json}")"
    fi
else
    MESSAGE="<code>Started</code> <a href=\"${URL}\">dump</a> <code>on</code> <a href=\"$BUILD_URL\">jenkins</a>."
    if _json="$(sendTG normal "${MESSAGE}")"; then
        # grab initial message id
        MESSAGE_ID="$(jq ".result.message_id" <<< "${_json}")"
    fi

    sendTG edit "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Downloading the file..</code>" > /dev/null
    downloadError() {
        echo "Download failed. Exiting."
        sendTG edit "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Failed to download the file.</code>" > /dev/null
        exit 1
    }
    if [[ $URL =~ drive.google.com ]]; then
        echo "Google Drive URL detected"
        FILE_ID="$(echo "${URL:?}" | sed -r 's/.*([0-9a-zA-Z_-]{33}).*/\1/')"
        echo "File ID is ${FILE_ID}"
        CONFIRM=$(wget --quiet --save-cookies /tmp/cookies.txt --keep-session-cookies --no-check-certificate "https://docs.google.com/uc?export=download&id=$FILE_ID" -O- | sed -rn 's/.*confirm=([0-9A-Za-z_]+).*/\1\n/p')
        aria2c --load-cookies /tmp/cookies.txt "https://docs.google.com/uc?export=download&confirm=$CONFIRM&id=$FILE_ID" || downloadError
        rm /tmp/cookies.txt
    elif [[ $URL =~ mega.nz ]]; then
        megadl "'$URL'" || downloadError
    else
        # Try to download certain URLs with axel first
        if [[ $URL =~ ^.+(ota\.d\.miui\.com|otafsg|h2os|oxygenos\.oneplus\.net|dl.google|android.googleapis|ozip)(.+)?$ ]]; then
            axel -q -a -n64 "$URL" || {
                # Try to download with aria, else wget. Clean the directory each time.
                aria2c -q -s16 -x16 "${URL}" || {
                    rm -fv ./*
                    wget "${URL}" || downloadError
                }
            }
        else
            # Try to download with aria, else wget. Clean the directory each time.
            aria2c -q -s16 -x16 "${URL}" || {
                rm -fv ./*
                wget "${URL}" || downloadError
            }
        fi
    fi
    MESSAGE="${MESSAGE}"$'\n'"<code>Downloaded the file.</code>"
    sendTG edit "${MESSAGE_ID}" "${MESSAGE}" > /dev/null
fi

FILE=${URL##*/}
EXTENSION=${URL##*.}
UNZIP_DIR=${FILE/.$EXTENSION/}
export UNZIP_DIR

if [[ ! -f ${FILE} ]]; then
    if [[ "$(find . -type f | wc -l)" != 1 ]]; then
        sendTG edit "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Can't seem to find downloaded file!</code>" > /dev/null
        exit 1
    else
        FILE="$(find . -type f)"
    fi
fi

EXTERNAL_TOOLS=(
    https://github.com/PabloCastellano/extract-dtb
    https://github.com/AndroidDumps/Firmware_extractor
    https://github.com/xiaolu/mkbootimg_tools
    https://github.com/marin-m/vmlinux-to-elf
)

for tool_url in "${EXTERNAL_TOOLS[@]}"; do
    tool_path="${HOME}/${tool_url##*/}"
    if ! [[ -d "${tool_path}" ]]; then
        git clone -q "${tool_url}" "${tool_path}"
    else
        git -C "${tool_path}" pull
    fi
done

sendTG edit "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Extracting file..</code>" > /dev/null
bash "${HOME}"/Firmware_extractor/extractor.sh "${FILE}" "${PWD}" || {
    sendTG edit "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Extraction failed!</code>" > /dev/null
    exit 1
}

rm -fv "$FILE"

PARTITIONS=(system systemex system_ext system_other
    vendor cust odm oem factory product modem
    xrom reserve india oppo_product opproduct
    my_preload my_odm my_stock my_operator my_country my_product my_company my_engineering my_heytap
)

# Extract the images
for p in "${PARTITIONS[@]}"; do
    if [[ -f $p.img ]]; then
        sendTG edit "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Extracting partition: ${p} ..</code>" > /dev/null
        mkdir "$p" || rm -rf "${p:?}"/*
        7z x "$p".img -y -o"$p"/ || {
            sudo mount -o loop "$p".img "$p"
            mkdir "${p}_"
            sudo cp -rf "${p}/*" "${p}_"
            sudo umount "${p}"
            sudo mv "${p}_" "${p}"
        }
        rm -fv "$p".img
    fi
done
MESSAGE="${MESSAGE}"$'\n'"<code>All partitions extracted.</code>"
sendTG edit "${MESSAGE_ID}" "${MESSAGE}"$'\n'"${MESSAGE}" > /dev/null

# Bail out right now if no system build.prop
ls system/build*.prop 2> /dev/null || ls system/system/build*.prop 2> /dev/null || {
    sendTG edit "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>No system build*.prop found, pushing cancelled!</code>" > /dev/null
    exit 1
}

if [[ ! -f "boot.img" ]]; then
    x=$(find . -type f -name "boot.img")
    if [[ -n $x ]]; then
        mv -v "$x" boot.img
    else
        echo "boot.img not found!"
    fi
fi

if [[ ! -f "dtbo.img" ]]; then
    x=$(find . -type f -name "dtbo.img")
    if [[ -n $x ]]; then
        mv -v "$x" dtbo.img
    else
        echo "dtbo.img not found!"
    fi
fi

# Extract bootimage and dtbo
if [[ -f "boot.img" ]]; then
    mkdir -v bootdts
    "${HOME}"/mkbootimg_tools/mkboot ./boot.img ./bootimg > /dev/null
    python3 "${HOME}"/extract-dtb/extract-dtb.py ./boot.img -o ./bootimg > /dev/null
    find bootimg/ -name '*.dtb' -type f -exec dtc -I dtb -O dts {} -o bootdts/"$(echo {} | sed 's/\.dtb/.dts/')" \; > /dev/null 2>&1

    # Extract ikconfig
    command -v extract-ikconfig > /dev/null &&
        extract-ikconfig boot.img > ikconfig

    # Kallsyms
    python3 "${HOME}"/vmlinux-to-elf/vmlinux_to_elf/kallsyms_finder.py boot.img > kallsyms.txt

    # ELF
    python3 "${HOME}"/vmlinux-to-elf/vmlinux_to_elf/main.py boot.img boot.elf
fi
if [[ -f "dtbo.img" ]]; then
    mkdir -v dtbodts
    python3 "${HOME}"/extract-dtb/extract-dtb.py ./dtbo.img -o ./dtbo > /dev/null
    find dtbo/ -name '*.dtb' -type f -exec dtc -I dtb -O dts {} -o dtbodts/"$(echo {} | sed 's/\.dtb/.dts/')" \; > /dev/null 2>&1
fi

# Oppo/Realme devices have some images in a euclid folder in their vendor, extract those for props
if [[ -d "vendor/euclid" ]]; then
    pushd vendor/euclid || exit 1
    for f in *.img; do
        [[ -f $f ]] || continue
        7z x "$f" -o"${f/.img/}"
        rm -fv "$f"
    done
    popd || exit 1
fi

# board-info.txt
find ./modem -type f -exec strings {} \; | grep "QC_IMAGE_VERSION_STRING=MPSS." | sed "s|QC_IMAGE_VERSION_STRING=MPSS.||g" | cut -c 4- | sed -e 's/^/require version-baseband=/' >> ./board-info.txt
find ./tz* -type f -exec strings {} \; | grep "QC_IMAGE_VERSION_STRING" | sed "s|QC_IMAGE_VERSION_STRING|require version-trustzone|g" >> ./board-info.txt
if [[ -f ./vendor/build.prop ]]; then
    strings ./vendor/build.prop | grep "ro.vendor.build.date.utc" | sed "s|ro.vendor.build.date.utc|require version-vendor|g" >> ./board-info.txt
fi
sort -u -o ./board-info.txt ./board-info.txt

# Fix permissions
sudo chown "$(whoami)" ./* -R
sudo chmod -R u+rwX ./*

# Generate all_files.txt
find . -type f -printf '%P\n' | sort | grep -v ".git/" > ./all_files.txt

# Prop extraction
sendTG edit "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Extracting props..</code>" > /dev/null

flavor=$(grep -oP "(?<=^ro.build.flavor=).*" -hs {system,system/system,vendor}/build.prop)
[[ -z ${flavor} ]] && flavor=$(grep -oP "(?<=^ro.build.flavor=).*" -hs {system,system/system,vendor}/build*.prop)
[[ -z ${flavor} ]] && flavor=$(grep -oP "(?<=^ro.vendor.build.flavor=).*" -hs vendor/build*.prop)
[[ -z ${flavor} ]] && flavor=$(grep -oP "(?<=^ro.system.build.flavor=).*" -hs {system,system/system}/build*.prop)
[[ -z ${flavor} ]] && flavor=$(grep -oP "(?<=^ro.build.type=).*" -hs {system,system/system}/build*.prop)

release=$(grep -oP "(?<=^ro.build.version.release=).*" -hs {system,system/system,vendor}/build*.prop)
[[ -z ${release} ]] && release=$(grep -oP "(?<=^ro.vendor.build.version.release=).*" -hs vendor/build*.prop)
[[ -z ${release} ]] && release=$(grep -oP "(?<=^ro.system.build.version.release=).*" -hs {system,system/system}/build*.prop)

id=$(grep -oP "(?<=^ro.build.id=).*" -hs {system,system/system,vendor}/build*.prop)
[[ -z ${id} ]] && id=$(grep -oP "(?<=^ro.vendor.build.id=).*" -hs vendor/build*.prop)
[[ -z ${id} ]] && id=$(grep -oP "(?<=^ro.system.build.id=).*" -hs {system,system/system}/build*.prop)

incremental=$(grep -oP "(?<=^ro.build.version.incremental=).*" -hs {system,system/system,vendor}/build*.prop)
[[ -z ${incremental} ]] && incremental=$(grep -oP "(?<=^ro.vendor.build.version.incremental=).*" -hs vendor/build*.prop)
[[ -z ${incremental} ]] && incremental=$(grep -oP "(?<=^ro.system.build.version.incremental=).*" -hs {system,system/system}/build*.prop)
[[ -z ${incremental} ]] && incremental=$(grep -oP "(?<=^ro.build.version.incremental=).*" -hs my_product/build*.prop)
[[ -z ${incremental} ]] && incremental=$(grep -oP "(?<=^ro.system.build.version.incremental=).*" -hs my_product/build*.prop)
[[ -z ${incremental} ]] && incremental=$(grep -oP "(?<=^ro.vendor.build.version.incremental=).*" -hs my_product/build*.prop)

tags=$(grep -oP "(?<=^ro.build.tags=).*" -hs {system,system/system,vendor}/build*.prop)
[[ -z ${tags} ]] && tags=$(grep -oP "(?<=^ro.vendor.build.tags=).*" -hs vendor/build*.prop)
[[ -z ${tags} ]] && tags=$(grep -oP "(?<=^ro.system.build.tags=).*" -hs {system,system/system}/build*.prop)

platform=$(grep -oP "(?<=^ro.board.platform=).*" -hs {system,system/system,vendor}/build*.prop)
[[ -z ${platform} ]] && platform=$(grep -oP "(?<=^ro.vendor.board.platform=).*" -hs vendor/build*.prop)
[[ -z ${platform} ]] && platform=$(grep -oP rg"(?<=^ro.system.board.platform=).*" -hs {system,system/system}/build*.prop)

manufacturer=$(grep -oP "(?<=^ro.product.manufacturer=).*" -hs {system,system/system,vendor}/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -oP "(?<=^ro.vendor.product.manufacturer=).*" -hs vendor/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -oP "(?<=^ro.system.product.manufacturer=).*" -hs {system,system/system}/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -oP "(?<=^ro.system.product.manufacturer=).*" -hs vendor/euclid/*/build.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -oP "(?<=^ro.product.manufacturer=).*" -hs oppo_product/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(grep -oP "(?<=^ro.product.manufacturer=).*" -hs my_product/build*.prop)

fingerprint=$(grep -oP "(?<=^ro.vendor.build.fingerprint=).*" -hs vendor/build.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -oP "(?<=^ro.build.fingerprint=).*" -hs {system,system/system}/build.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -oP "(?<=^ro.build.fingerprint=).*" -hs {system,system/system}/build*.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -oP "(?<=^ro.vendor.build.fingerprint=).*" -hs vendor/build*.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -oP "(?<=^ro.product.build.fingerprint=).*" -hs product/build.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -oP "(?<=^ro.product.build.fingerprint=).*" -hs product/build*.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -oP "(?<=^ro.system.build.fingerprint=).*" -hs {system,system/system}/build*.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -oP "(?<=^ro.build.fingerprint=).*" -hs my_product/build.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -oP "(?<=^ro.system.build.fingerprint=).*" -hs my_product/build.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(grep -oP "(?<=^ro.vendor.build.fingerprint=).*" -hs my_product/build.prop)

brand=$(grep -oP "(?<=^ro.product.brand=).*" -hs {system,system/system,vendor}/build*.prop | head -1)
[[ -z ${brand} ]] && brand=$(grep -oP "(?<=^ro.product.vendor.brand=).*" -hs vendor/build*.prop | head -1)
[[ -z ${brand} ]] && brand=$(grep -oP "(?<=^ro.vendor.product.brand=).*" -hs vendor/build*.prop | head -1)
[[ -z ${brand} ]] && brand=$(grep -oP "(?<=^ro.product.system.brand=).*" -hs {system,system/system}/build*.prop | head -1)
[[ -z ${brand} || ${brand} == "OPPO" ]] && brand=$(grep -oP "(?<=^ro.product.system.brand=).*" -hs vendor/euclid/*/build.prop | head -1)
[[ -z ${brand} ]] && brand=$(grep -oP "(?<=^ro.product.odm.brand=).*" -hs vendor/odm/etc/build*.prop)
[[ -z ${brand} ]] && brand=$(grep -oP "(?<=^ro.product.brand=).*" -hs oppo_product/build*.prop)
[[ -z ${brand} ]] && brand=$(grep -oP "(?<=^ro.product.brand=).*" -hs my_product/build*.prop)
[[ -z ${brand} ]] && brand=$(echo "$fingerprint" | cut -d / -f1)

codename=$(grep -oP "(?<=^ro.product.device=).*" -hs {system,system/system,vendor}/build*.prop | head -1)
[[ -z ${codename} ]] && codename=$(grep -oP "(?<=^ro.product.vendor.device=).*" -hs vendor/build*.prop | head -1)
[[ -z ${codename} ]] && codename=$(grep -oP "(?<=^ro.vendor.product.device=).*" -hs vendor/build*.prop | head -1)
[[ -z ${codename} ]] && codename=$(grep -oP "(?<=^ro.product.system.device=).*" -hs {system,system/system}/build*.prop | head -1)
[[ -z ${codename} ]] && codename=$(grep -oP "(?<=^ro.product.system.device=).*" -hs vendor/euclid/*/build.prop | head -1)
[[ -z ${codename} ]] && codename=$(grep -oP "(?<=^ro.product.device=).*" -hs oppo_product/build*.prop)
[[ -z ${codename} ]] && codename=$(grep -oP "(?<=^ro.product.device=).*" -hs my_product/build*.prop)
[[ -z ${codename} ]] && codename=$(grep -oP "(?<=^ro.product.system.device=).*" -hs my_product/build*.prop)
[[ -z ${codename} ]] && codename=$(grep -oP "(?<=^ro.product.vendor.device=).*" -hs my_product/build*.prop)
[[ -z ${codename} ]] && codename=$(grep -oP "(?<=^ro.build.fota.version=).*" -hs {system,system/system}/build*.prop | cut -d - -f1 | head -1)
[[ -z ${codename} ]] && codename=$(echo "$fingerprint" | cut -d / -f3 | cut -d : -f1)

description=$(grep -oP "(?<=^ro.build.description=).*" -hs {system,system/system}/build.prop)
[[ -z ${description} ]] && description=$(grep -oP "(?<=^ro.build.description=).*" -hs {system,system/system}/build*.prop)
[[ -z ${description} ]] && description=$(grep -oP "(?<=^ro.vendor.build.description=).*" -hs vendor/build.prop)
[[ -z ${description} ]] && description=$(grep -oP "(?<=^ro.vendor.build.description=).*" -hs vendor/build*.prop)
[[ -z ${description} ]] && description=$(grep -oP "(?<=^ro.product.build.description=).*" -hs product/build.prop)
[[ -z ${description} ]] && description=$(grep -oP "(?<=^ro.product.build.description=).*" -hs product/build*.prop)
[[ -z ${description} ]] && description=$(grep -oP "(?<=^ro.system.build.description=).*" -hs {system,system/system}/build*.prop)
[[ -z ${description} ]] && description="$flavor $release $id $incremental $tags"

sendTG edit "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>All props extracted.</code>" > /dev/null

branch="${description// /_}"
repo_subgroup="${brand,,}"
[[ -z $repo_subgroup ]] && repo_subgroup="${manufacturer,,}"
repo_name="${codename,,}"
repo="$repo_subgroup/$repo_name"
platform="$(: "${platform,,}" && : "${_//_/-/}" && printf "%s\n" "${_:0:135}")"
top_codename="$(: "${codename,,}" && : "${_//_/-/}" && printf "%s\n" "${_:0:135}")"
manufacturer="$(: "${manufacturer,,}" && : "${_//_/-/}" && printf "%s\n" "${_:0:135}")"

printf "\n%s\n\n" \
    "flavor: $flavor
    release: $release
    id: $id
    incremental: $incremental
    tags: $tags
    fingerprint: $fingerprint
    brand: $brand
    codename: $codename
    description: $description
    branch: $branch
    repo: $repo
    manufacturer: $manufacturer
    platform: $platform
    top_codename: $top_codename"

# Check whether the subgroup exists or not
if ! group_id_json="$(curl -s -H "Authorization: Bearer $DUMPER_TOKEN" "https://git.rip/api/v4/groups/$ORG%2f$repo_subgroup" -s --fail)"; then
    if ! group_id_json="$(curl -H "Authorization: Bearer $DUMPER_TOKEN" "https://git.rip/api/v4/groups" -X POST -F name="${repo_subgroup^}" -F parent_id=562 -F path="${repo_subgroup}" --silent --fail)"; then
        sendTG edit "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Creating subgroup for $repo_subgroup failed!</code>" > /dev/null
        exit 1
    fi
fi

if ! group_id="$(jq '.id' -e <<< "${group_id_json}")"; then
    sendTG edit "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Unable to get gitlab group id!</code>" > /dev/null
    exit 1
fi

# Create the repo if it doesn't exist
project_id_json="$(curl --silent -H "Authorization: bearer ${DUMPER_TOKEN}" "https://git.rip/api/v4/projects/$ORG%2f$repo_subgroup%2f$repo_name")"
if ! project_id="$(jq .id -e <<< "${project_id_json}")"; then
    project_id_json="$(curl --silent -H "Authorization: bearer ${DUMPER_TOKEN}" "https://git.rip/api/v4/projects" -X POST -F namespace_id="$group_id" -F name="$repo_name" -F visibility=public)"
    if project_id="$(jq .id -e <<< "${project_id_json}")"; then
        sendTG edit "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Could not get project id!</code>" > /dev/null
        exit 1
    fi
fi

branch_json="$(curl --silent -H "Authorization: bearer ${DUMPER_TOKEN}" "https://git.rip/api/v4/projects/$project_id/repository/branches/$branch")"
[[ "$(jq '.name' -e <<< "${branch_json}")" == "$branch" ]] && {
    sendTG edit "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>$branch already exists in</code> <a href=\"https://git.rip/dumps/$repo\">$repo</a>!" > /dev/null
    exit 1
}

# Add, commit, and push after filtering out certain files
git init
git config user.name 'dumper'
git config user.email '457-dumper@users.noreply.git.rip'
git checkout -b "$branch"
find . -size +97M -printf '%P\n' -o -name '*sensetime*' -printf '%P\n' -o -iname '*Megvii*' -printf '%P\n' -o -name '*.lic' -printf '%P\n' -o -name '*zookhrs*' -printf '%P\n' > .gitignore

sendTG edit "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Committing..</code>" > /dev/null
git add -A
git commit --quiet --signoff --message="$description"

sendTG edit "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Pushing..</code>" > /dev/null
git push "https://dumper:$DUMPER_TOKEN@git.rip/$ORG/$repo.git" HEAD:refs/heads/"$branch" || {
    sendTG edit "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Pushing failed!</code>" > /dev/null
    echo "Pushing failed!"
    exit 1
}

# Set default branch to the newly pushed branch
curl -s -H "Authorization: bearer ${DUMPER_TOKEN}" "https://git.rip/api/v4/projects/$project_id" -X PUT -F default_branch="$branch" > /dev/null

# Send message to Telegram group
sendTG edit "${MESSAGE_ID}" "${MESSAGE}"$'\n'"<code>Pushed</code> <a href=\"https://git.rip/$ORG/$repo\">$description</a>" > /dev/null

# Prepare message to be sent to Telegram channel
commit_head=$(git rev-parse HEAD)
commit_link="https://git.rip/$ORG/$repo/commit/$commit_head"
echo -e "Sending telegram notification"
TEXT="<b>Brand: $brand</b>
<b>Device: $codename</b>
<b>Version:</b> $release
<b>Fingerprint:</b> $fingerprint
<b>Git link:</b>
<a href=\"$commit_link\">Commit</a>
<a href=\"https://git.rip/$ORG/$repo/tree/$branch/\">$codename</a>"

# Send message to Telegram channel
curl -s "https://api.telegram.org/bot${API_KEY}/sendmessage" --data "text=${TEXT}&chat_id=@android_dumps&parse_mode=HTML&disable_web_page_preview=True" > /dev/null
