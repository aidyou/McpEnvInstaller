#!/bin/bash

# Debian
docker run --rm -v "$(pwd)":/app -w /app debian:latest /bin/bash -c 'apt-get update && apt-get install -y ca-certificates && mkdir -p /etc/apt/sources.list.d && echo "deb https://mirrors.aliyun.com/debian/ stable main" > /etc/apt/sources.list.d/aliyun.list && apt-get update && chmod +x /app/linux.sh && /app/linux.sh'

# CentOS
docker run --rm -v "$(pwd)":/app -w /app centos:latest /bin/bash -c 'sed -i -e "s|^mirrorlist=|#mirrorlist=|g" -e "s|^#baseurl=http://mirror.centos.org|baseurl=https://mirrors.aliyun.com|g" /etc/yum.repos.d/CentOS-*.repo && yum clean all && yum makecache && chmod +x /app/linux.sh && /app/linux.sh'

# Arch Linux
docker run --rm -v "$(pwd)":/app -w /app archlinux:latest /bin/bash -c 'sed -i "s|^#Server = http://mirrors.aliyun.com|Server = https://mirrors.aliyun.com|g" /etc/pacman.d/mirrorlist && pacman -Sy --noconfirm && chmod +x /app/linux.sh && /app/linux.sh'

# OpenSUSE
docker run --rm -v "$(pwd)":/app -w /app opensuse/leap:latest /bin/bash -c 'sed -i "s|http://download.opensuse.org|https://mirrors.aliyun.com/opensuse|g" /etc/zypp/repos.d/*.repo && zypper --non-interactive refresh && chmod +x /app/linux.sh && /app/linux.sh'

# Alpine
docker run --rm -v "$(pwd)":/app -w /app alpine:latest /bin/sh -c 'sed -i "s|http://dl-cdn.alpinelinux.org|https://mirrors.aliyun.com|g" /etc/apk/repositories && apk update && apk add bash && chmod +x /app/linux.sh && /app/linux.sh'