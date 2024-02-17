#!/usr/bin/env bash
set -e
from=$1
to=$2

if [ -z "$from" ] || [ -z "$to" ]; then
	echo 'pass 2 positional parameters - $from and $to'
	exit 1
fi

commands=()
# Update terraform modules
for file in $(grep -rni "\"istio-injection\" : \"$from\"" . | grep -v '#' | awk '{print $1}' | cut -d':' -f1); do
	echo $file
	sed -i "s/istio-injection\" : \"$from\"/istio-injection\" : \"$to\"/" $file

	ns=$(echo $file | cut -d'/' -f 4)
	commands+=("kubectl -n $ns get deployments --no-headers | awk '{print \$1}' | xargs kubectl -n $ns rollout restart deployment")
done

# Apply changes
terraform apply -auto-approve

# Restart deployments
for cmd in "${commands[@]}"; do
	echo $cmd
	bash -c "$cmd"
done
