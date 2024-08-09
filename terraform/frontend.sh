#!/bin/bash
# component = $1
# environment = $2
dnf install ansible -y
pip3.9 install botocore boto3
ansible-pull -i localhost, -U https://github.com/NagamaniPalemkota/expense-ansible-roles-tf.git main.yaml -e component=$1 -e env=$2 -e appVersion=$3