#!/bin/bash
#安装python3.10

version=3.10.19
short_bin="${version:0:4}"
cd python3.10-rpms
sudo rpm -Uvh --force --nodeps *.rpm
cd ../
tar -xzf Python-${version}.tgz
cd Python-${version}
./configure --enable-optimizations --prefix=/usr/local/python${short_bin}
make -j$(nproc)
sudo make altinstall
sudo ln -sf /usr/local/python3.10/bin/python3.10 /usr/bin/python${short_bin}
sudo ln -sf /usr/local/python3.10/bin/pip3.10 /usr/bin/pip${short_bin}
python3.10 --version




