# Check Service Version

Find the version of a specific service deployed in this infrastructure.

Search for the service name in modules/kubernetes/ and extract:
1. The image version/tag being used
2. Any version variables defined
3. The Helm chart version if applicable

Service to check: $ARGUMENTS
