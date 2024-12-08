#!/bin/bash

# exit when any command fails
set -e


validate_boolean_input() {
  # Validate the value is a recognized boolean, and set it to "" if it's false.
  local input_value="$1"
  local output_variable="$2"

  if [[ "$input_value" =~ ^(true|True|1)$ ]]; then
    echo "- ${output_variable,,}: true"
    eval "$output_variable=true"
  elif [[ "$input_value" =~ ^(false|False|0)$ ]]; then
    echo "- ${output_variable,,}: false"
    eval "$output_variable="
  else
    echo "::error title=BinderDocker::Invalid input value for '${output_variable,,}': '$input_value'. Allowed values are: 'true', 'True', '1', 'false', 'False', '0'."
    exit 1
  fi
}


generate_image_names() {
    IMAGE_NAMES=()

    local input_image_name="$INPUT_IMAGE_NAME"
    local input_image_tags="$INPUT_IMAGE_TAGS"
    local -a image_tags

    # Convert image name to lowercase
    input_image_name="${input_image_name,,}"
    # Parse INPUT_IMAGE_TAGS into an array (space-separated by default)
    read -r -a image_tags <<< "$input_image_tags"
    # Create the IMAGE_NAMES array by prepending IMAGE_NAME to each tag
    for tag in "${image_tags[@]}"; do
        IMAGE_NAMES+=("${input_image_name}:${tag}")
    done
    echo "- image names: ${IMAGE_NAMES[@]}"
    echo "image_names=${IMAGE_NAMES[@]}" >> $GITHUB_OUTPUT
}


generate_cache_image_names() {
    # Generate and write CACHE_IMAGE_NAMES
    CACHE_IMAGE_NAMES=()

    local -a cache_image_tags

    read -r -a CACHE_IMAGE_NAMES <<< "$INPUT_CACHE_IMAGE_NAMES"
    read -r -a cache_image_tags <<< "$INPUT_CACHE_IMAGE_TAGS"

    for cache_image_tag in "${cache_image_tags[@]}"; do
        CACHE_IMAGE_NAMES+=("${INPUT_IMAGE_NAME,,}:${cache_image_tag,,}")
    done
    echo "- cache image names: ${CACHE_IMAGE_NAMES}"
}


get_fullpath() {
    local rel_path="$1"
    local normalized_path
    local fullpath

    normalized_path=$(echo "$rel_path" | sed 's:/*$::')
    if [ "$normalized_path" = "." ] || [ -z "$normalized_path" ]; then
        fullpath="${PWD}"
    else
        fullpath="${PWD}/${normalized_path}"
    fi
    echo "$fullpath"
}


echo "::group::🖲 Inputs"
# Verify required inputs
required_vars=("IMAGE_NAME" "IMAGE_TAGS" "IMAGE_USER" "GIT_REF")
for var_name in "${required_vars[@]}"; do
    full_var_name="INPUT_$var_name"
    if [ -z "${!full_var_name}" ]; then
        echo "::error title=BinderDocker::Required input '$full_var_name' is not defined or is empty."
        exit 1
    else
        echo "- ${var_name,,}: ${!full_var_name}"
    fi
done
validate_boolean_input "$INPUT_PUSH" "PUSH"
generate_image_names
generate_cache_image_names
# image_dir
if [ -z "$INPUT_IMAGE_DIR" ]; then
  IMAGE_DIR="/home/${INPUT_IMAGE_USER}"
else
  IMAGE_DIR="${INPUT_IMAGE_DIR}"
fi
echo "- image_dir: ${IMAGE_DIR}"
# dockerfile_append
if [ "$INPUT_DOCKERFILE_APPEND" ]; then
    APPENDIX=`cat $INPUT_DOCKERFILE_APPEND`
    echo "Dockerfile appendix:\n$APPENDIX"
fi
git_path=$(get_fullpath "${INPUT_GIT_PATH}")
echo "- git_path: ${git_path}"
echo "::endgroup::"


# Docker login
if [[ -n "$INPUT_DOCKER_USERNAME" && -n "$INPUT_DOCKER_PASSWORD" ]]; then
    echo ${INPUT_DOCKER_PASSWORD} | docker login $INPUT_DOCKER_REGISTRY -u ${INPUT_DOCKER_USERNAME} --password-stdin
fi


# Docker info
echo "::group::ℹ️ Docker Info"
docker info
echo "::endgroup::"


# Cache pull
cache_from=""
for cache_image_name in "${CACHE_IMAGE_NAMES[@]}"; do
    echo "::group::📥 Cache Pull: ${cache_image_name}"
    if docker pull "${cache_image_name}"; then
        cache_from+="--cache-from '${cache_image_name}' "
    else
        echo "::warning title=BinderDocker::Failed to pull cache image '${cache_image_name}'."
    fi
    echo "::endgroup::"
done


# repo2docker version update
if [[ -n "${INPUT_REPO2DOCKER_VERSION}" ]]; then
    echo "::group::📲 Repo2docker ${INPUT_REPO2DOCKER_VERSION} Installation"
    python3 -m pip install --upgrade --force ${INPUT_REPO2DOCKER_VERSION}
    echo "::endgroup::"
fi


# Build
echo "::group::🏗 Build"
# Explicitly specify repo and ref labels, as repo2docker only knows it is building something local.
# Don't quote ${INPUT_REPO2DOCKER_ARGS},
# as it *should* be interpreted as arbitrary arguments to be passed to repo2docker.
# Instead, use eval to correctly evaluate the entire command
# (see https://stackoverflow.com/questions/30061682/bash-send-string-argument-as-multiple-arguments).
eval "jupyter-repo2docker \
    --no-run \
    --user-id 1000 \
    --user-name '${INPUT_IMAGE_USER}' \
    --target-repo-dir '${IMAGE_DIR}' \
    --image-name '${IMAGE_NAMES[0]}' \
    --label 'repo2docker.repo=https://github.com/${GITHUB_REPOSITORY}' \
    --label 'repo2docker.ref=${INPUT_GIT_REF}' \
    --appendix '${APPENDIX}' \
    ${cache_from} \
    ${INPUT_REPO2DOCKER_ARGS} \
    '${git_path}'"
echo "::endgroup::"


# Tag
for image_name in "${IMAGE_NAMES[@]:1}"; do
    echo "::group::🏷 Tag: ${image_name}"
    docker tag "${IMAGE_NAMES[0]}" "$image_name"
    echo "::endgroup::"
done


# Test
if [[ -n "${INPUT_TEST_SCRIPT}" ]]; then
    echo "::group::🧪 Test"
    docker run -u 1000 -w "${IMAGE_DIR}" "${IMAGE_NAMES[0]}" /bin/bash -c "eval '${INPUT_TEST_SCRIPT}'"
    echo "::endgroup::"
fi


# Push
if [[ -n "$PUSH" ]]; then
    for image_name in "${IMAGE_NAMES[@]}"; do
        echo "::group::📤 Push ${image_name}"
        docker push "$image_name"
        echo "::endgroup::"
    done
    # Digest
    DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "${INPUT_IMAGE_NAME,,}" | cut -d'@' -f2)
    echo "🔐 SHA digest: $DIGEST"
    echo "image_digest=$DIGEST" >> $GITHUB_OUTPUT
    docker logout
fi
