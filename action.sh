#!/bin/bash

# exit when any command fails
set -e -x

validate_boolean_input() {
  # Validate the value is a recognized boolean, and set it to "" if it's false.
  local input_value="$1"
  local output_variable="$2"

  if [[ "$input_value" =~ ^(true|True|1)$ ]]; then
    echo "${output_variable,,}: true"
    eval "$output_variable=true"
  elif [[ "$input_value" =~ ^(false|False|0)$ ]]; then
    echo "${output_variable,,}: false"
    eval "$output_variable="
  else
    echo "::error title=BinderDocker::Invalid input value for '${output_variable}': '$input_value'. Allowed values are: 'true', 'True', '1', 'false', 'False', '0'."
    exit 1
  fi
}

generate_image_names() {
    local input_image_name="$INPUT_IMAGE_NAME"
    local input_docker_username="$INPUT_DOCKER_USERNAME"
    local input_docker_registry="$INPUT_DOCKER_REGISTRY"
    local github_repository="$GITHUB_REPOSITORY"
    local input_image_tags="$INPUT_IMAGE_TAGS"

    local image_name
    local repo_name
    local -a image_tags
    local -a image_names

    # Determine IMAGE_NAME based on environment variables
    if [ -z "$input_image_name" ]; then
        if [[ -z "$input_docker_username" ]]; then
            image_name="$github_repository"
        else
            repo_name=$(echo "$github_repository" | cut -d "/" -f 2)
            image_name="$input_docker_username/$repo_name"
        fi
    else
        image_name="$input_image_name"
    fi

    # Prepend image name with registry if supplied
    if [ "$input_docker_registry" ]; then
        image_name="$input_docker_registry/$image_name"
    fi

    # Convert image name to lowercase
    image_name="${image_name,,}"

    # Parse INPUT_IMAGE_TAGS into an array (space-separated by default)
    read -r -a image_tags <<< "$input_image_tags"
    echo "image_tags: ${image_tags[@]}"

    # Create the IMAGE_NAMES array by prepending IMAGE_NAME to each tag
    for tag in "${image_tags[@]}"; do
        image_names+=("${image_name}:${tag}")
    done
    echo "Full image names: ${image_names[@]}"

    echo "${image_names[@]}"
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


echo "::group::Input Processing"
validate_boolean_input "$INPUT_PUSH" "PUSH"
validate_boolean_input "$INPUT_CHECK_PUBLIC" "CHECK_PUBLIC"
# image_user
if [ -z "$INPUT_IMAGE_USER" ]; then
  echo "::error title=BinderDocker::Input 'image_user' is required."
  exit 1
fi
# image_names
IMAGE_NAMES=($(generate_image_names))
echo "image-names=${IMAGE_NAMES[@]}" >> $GITHUB_OUTPUT
# image_dir
if [ -z "$INPUT_IMAGE_DIR" ]; then
  IMAGE_DIR="/home/${INPUT_IMAGE_USER}"
else
  IMAGE_DIR="${INPUT_IMAGE_DIR}"
fi
echo "image_dir: ${IMAGE_DIR}"
# dockerfile_append
if [ "$INPUT_DOCKERFILE_APPEND" ]; then
    APPENDIX=`cat $INPUT_DOCKERFILE_APPEND`
    echo "Dockerfile appendix:\n$APPENDIX"
fi
git_path=$(get_full_path "${INPUT_GIT_PATH}")
echo "git_path: ${git_path}"
echo "::endgroup::"


# Docker login
if [[ -n "$PUSH" ]]; then
    echo "::group::Docker Login"
    echo ${INPUT_DOCKER_PASSWORD} | docker login $INPUT_DOCKER_REGISTRY -u ${INPUT_DOCKER_USERNAME} --password-stdin
    echo "::endgroup::"
fi


# Cache pull
read -r -a cache_image_names <<< "$INPUT_CACHE_IMAGE_NAMES"
cache_from=""
for cache_image_name in "${cache_image_names[@]}"; do
    echo "::group::Pull Cache Image ${cache_image_name}"
    if docker pull "${cache_image_name}"; then
        cache_from+="--cache-from ${cache_image_name} "
    else
        echo "::warning title=BinderDocker::Failed to pull cache image '${cache_image_name}'."
    fi
    echo "::endgroup::"
done


# repo2docker version update
if [[ -n "${INPUT_REPO2DOCKER_VERSION}" ]]; then
    echo "::group::Repo2docker ${INPUT_REPO2DOCKER_VERSION} Installation"
    python3 -m pip install --upgrade --force ${INPUT_REPO2DOCKER_VERSION}
    echo "::endgroup::"
fi


# Build
echo "::group::Build"
# Explicitly specify repo and ref labels, as repo2docker only knows it is building something local.
# Don't quote ${INPUT_REPO2DOCKER_ARGS}, as it *should* be interpreted as arbitrary arguments to be passed to repo2docker.
jupyter-repo2docker \
    --no-run \
    --user-id 1000 \
    --user-name ${NB_USER} \
    --target-repo-dir ${IMAGE_DIR} \
    --image-name ${IMAGE_NAMES[0]} \
    --label "repo2docker.repo=https://github.com/${GITHUB_REPOSITORY}" \
    --label "repo2docker.ref=${INPUT_GIT_REF}" \
    --appendix "$APPENDIX" \
    ${cache_from} \
    ${INPUT_REPO2DOCKER_ARGS} \
    ${git_path}
echo "::endgroup::"


# Tag
for image_name in "${IMAGE_NAMES[@]:1}"; do
    echo "::group::Tag $image_name"
    docker tag "${IMAGE_NAMES[0]}" "$image_name"
    echo "::endgroup::"
done


# Test
if [[ -n "${INPUT_TEST_SCRIPT}" ]]; then
    echo "::group::Test"
    docker run -u 1000 -w "${IMAGE_DIR}" "${IMAGE_NAMES[0]}" /bin/bash -c "eval '${INPUT_TEST_SCRIPT}'"
    echo "::endgroup::"
fi


# Push
if [[ -n "$PUSH" ]]; then
  for image_name in "${IMAGE_NAMES[@]}"; do
      echo "::group::Push $image_name"
      docker push "$image_name"
      echo "::endgroup::"
  done
  if [[ -n "$CHECK_PUBLIC" ]]; then
      docker logout
      for image_name in "${IMAGE_NAMES[@]}"; do
          echo "::group::Public Status Validation: ${image_name}"
          if docker pull "${image_name}"; then
              echo "${image_name} is publicly visible."
          else
              echo "::warning title=BinderDocker::Pushed image '${image_name}' is not publicly visible."
          fi
          echo "::endgroup::"
      done
  fi
fi
