#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

set -euo pipefail

# Read active APT sources without fetching indexes. A local mirror
# URI names a list file, so check the URLs in that list as well.
sources=$(apt-get indextargets --no-release-info --format "\$(REPO_URI)" | sort -u)
found_https=false
check_https() {
    if [[ "$1" != https://* ]]; then
        echo 'Expected HTTPS for all APT sources and mirrors' >&2
        exit 1
    fi
    found_https=true
}

if [[ -n "$sources" ]]; then
    while IFS= read -r uri; do
        if [[ "$uri" == mirror+file:* ]]; then
            list=${uri#mirror+file:}
            while read -r mirror _ || [[ -n "$mirror" ]]; do
                if [[ -n "$mirror" && "$mirror" != \#* ]]; then
                    check_https "$mirror"
                fi
            done < "${list%/}"
        else
            check_https "$uri"
        fi
    done <<< "$sources"
fi

if [[ "$found_https" != true ]]; then
    echo 'APT reported no HTTPS sources or mirrors' >&2
    exit 1
fi
