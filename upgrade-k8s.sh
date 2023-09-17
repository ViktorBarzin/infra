#!/usr/bin/env bash

VERSION=$1

sudo apt update
sudo apt upgrade kubeadm=$1
