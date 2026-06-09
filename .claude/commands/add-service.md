# Add New Service

Help create a new Kubernetes service module.

Service name: $ARGUMENTS

Steps:
1. Create directory at modules/kubernetes/<service-name>/
2. Create main.tf with:
   - Namespace resource
   - Deployment with appropriate container
   - Service resource
   - Ingress with TLS and standard annotations
3. Use existing patterns from similar services
4. Add module reference in main.tf
5. Update .claude/CLAUDE.md with new service version
