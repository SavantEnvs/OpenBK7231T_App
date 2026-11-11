# syntax=docker/dockerfile:1.7
# Commit image for OpenBK7231T_App: the Linux simulator (custom.mk) built with ASan+UBSan plus
# libFuzzer harnesses over its HTTP, command-interpreter and TuyaMCU parsers.
FROM ghcr.io/savantenvs/base:20261023

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS
ARG COVERAGE_FLAGS=
ARG MAYHEM_JOBS=

# The Berry scripting engine is an (uninitialised) git submodule upstream: pin the same commit the
# submodule points at and cache it where the air-gapped build.sh can read it.
USER root
ARG BERRY_COMMIT=b9ce913d9d43bb296d9604bc0cb4f2f68a6b703f
ARG BERRY_SHA256=b8d3501b2e21f01e681dee1109e83b4e8e2e7538700253212756ec8c3ff46e0e
RUN d=/opt/toolchains/deps/berry-${BERRY_COMMIT} && mkdir -p "$d/src" \
 && curl -fsSL -o /tmp/berry.tgz https://github.com/berry-lang/berry/archive/${BERRY_COMMIT}.tar.gz \
 && echo "${BERRY_SHA256}  /tmp/berry.tgz" | sha256sum -c - \
 && tar -xzf /tmp/berry.tgz --strip-components=1 -C "$d/src" \
 && rm /tmp/berry.tgz && chmod -R a+rX "$d"

USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN if [ -x /opt/mayhem/ccache/prefill ]; then /opt/mayhem/ccache/prefill bash mayhem/build.sh; \
    else bash mayhem/build.sh; fi

RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
