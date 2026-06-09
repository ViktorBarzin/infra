# Build notes

## Build

```
docker build --platform linux/amd64 -t {{IMAGE_NAME}}:{{TAG}} .
```

## Run

```
docker run --rm -p {{CONTAINER_PORT}}:{{CONTAINER_PORT}} {{IMAGE_NAME}}:{{TAG}}
```

## Configuration

{{ENV_VARS_TABLE}}

## Notes

- Built for `linux/amd64`; multi-arch not tested.
- Image size: `{{IMAGE_SIZE}}`, base: `{{BASE_IMAGE}}`.
- Runs as a non-root user.
{{EXTRA_NOTES}}
