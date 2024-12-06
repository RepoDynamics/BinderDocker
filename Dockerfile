FROM quay.io/jupyterhub/repo2docker:main

RUN apk add --no-cache curl jq build-base python3 python3-dev py3-pip

RUN python3 -m pip install --upgrade wheel setuptools

# Manually downgrade version of docker-py
# Until a fix for https://github.com/docker/docker-py/issues/3240
# is released, we want to use an older version of docker-py
RUN pip install 'docker!=7.0.0'

# https://stackoverflow.com/a/41651363/1695486
RUN apk add --no-cache curl curl-dev
COPY action.sh /action.sh

ENTRYPOINT ["/bin/bash", "/action.sh"]
