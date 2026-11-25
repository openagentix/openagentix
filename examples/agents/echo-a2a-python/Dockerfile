# syntax=docker/dockerfile:1
# ci-build: build this image in CI although it has no Go stage (hack/ci/dockerfiles.sh)
# Base: python:3.13-slim, the multi-arch index digest read from Docker Hub on 2026-11-25. To update it, see the README.
ARG PYTHON_IMAGE=python:3.13-slim@sha256:7249d5587b78209a006dc4a3b5340678f84ea729239193aa559962cd8c1fce50

FROM ${PYTHON_IMAGE} AS build
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1
COPY requirements.txt /tmp/requirements.txt
# Every package is pinned with its hash; --no-deps because the file is already the full closure.
RUN python -m venv /opt/venv \
 && /opt/venv/bin/pip install --require-hashes --no-deps -r /tmp/requirements.txt
COPY agent.py /app/agent.py
# Compile now: the root file system is read-only at run time, so Python cannot write .pyc files then.
RUN /opt/venv/bin/python -m compileall -q /app /opt/venv

FROM ${PYTHON_IMAGE}
ENV PATH=/opt/venv/bin:$PATH PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PORT=8080
COPY --from=build /opt/venv /opt/venv
COPY --from=build /app /app
WORKDIR /app
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["python", "/app/agent.py"]
