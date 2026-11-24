#!/bin/bash
# DNS labels as used by Docker site names and the host of a contact address.
valid_host_labels() {
    local LC_ALL=C host=$1 label
    local -a labels
    [[ $host =~ ^[A-Za-z0-9.-]+$ && $host != .* && $host != *. && $host != *..* ]] || return 1
    IFS=. read -r -a labels <<< "$host"
    for label in "${labels[@]}"; do
        [[ $label =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
    done
}

valid_public_hostname() {
    local LC_ALL=C host=$1
    [[ $host == *.* && ${host##*.} =~ ^([A-Za-z]{2,}|[Xx][Nn]--[A-Za-z0-9-]+)$ ]] &&
        valid_host_labels "$host"
}

valid_contact_address() {
    local LC_ALL=C address=$1
    [[ $address == *@* && ${address%@*} =~ ^[A-Za-z0-9._%+-]+$ ]] &&
        valid_public_hostname "${address##*@}"
}
