# GPU container

FROM ubuntu

ENV DEBIAN_FRONTEND=noninteractive

# Install Python and pip
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
        python3-venv

# Deps
RUN apt-get install -y ffmpeg espeak-ng

# Set a working directory
WORKDIR /app

RUN python3 -m venv audiblez && ./audiblez/bin/pip install audiblez
# RUN python3 -m venv audiblez 

CMD ["/usr/bin/sleep", "86400"]
# RUN pip install audiblez

# # Default command
# CMD ["/usr/bin/sleep", "86400"]
