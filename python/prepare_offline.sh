#!/bin/bash
set -e
version=3.10.19

wget https://www.python.org/ftp/python/${version}/Python-${version}.tgz

mkdir -p python3.10-rpms
cd python3.10-rpms

sudo dnf download --resolve \
  gcc make openssl-devel bzip2-devel libffi-devel zlib-devel \
  libuuid-devel xz-devel ncurses-devel readline-devel sqlite-devel