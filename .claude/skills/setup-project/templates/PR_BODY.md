## Add a working Dockerfile

### Why
{{REASON_PARAGRAPH}}

### What this adds
- `Dockerfile` — {{DOCKERFILE_SHAPE}}
- `.dockerignore`
- `BUILD.md` with the build command and notes

### Tested
- Built and pushed to a private registry, deployed to a Kubernetes cluster.
- Pod has been Ready and serving HTTP 200 at the ingress for 10+ minutes of continuous probing before this PR was opened.
- Image size: {{IMAGE_SIZE}}, base: {{BASE_IMAGE}}
- Platform tested: `linux/amd64`

### Build command
```
docker build --platform linux/amd64 -t {{IMAGE_TAG}} .
```

Happy to iterate on base image, build args, or multi-arch support if you'd prefer a different shape. Thanks for the project!

---
<sub>Contributed after self-hosting this project. Filed by the repo owner's deployment workflow; feel free to mention me (@ViktorBarzin) with any follow-ups.</sub>
