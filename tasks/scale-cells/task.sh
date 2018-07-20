#!/usr/bin/env bash

set -eu

product_guid=
cells=
job=diego_cell

get_status () {
  local product="${1}"

  echo "Finding PAS product GUID..."
  product_guid=$(
    om-linux \
      --target "$opsman_target" \
      --username "$opsman_user" \
      --password "$opsman_password" \
      --skip-ssl-validation \
      curl \
      --path /api/v0/staged/products \
      --silent |
      jq --raw-output ".[] | select ( .type == \"${product}\" ) | .guid"
  )

  echo "Getting job status..."
  om-linux \
    --target "$opsman_target" \
    --username "$opsman_user" \
    --password "$opsman_password" \
    --skip-ssl-validation \
    curl \
    --path /api/v0/deployed/products/${product_guid}/status \
    --silent > status/job-status.json
}

average_memory () {
  echo "Determining average memory allocation per cell..."
  cells=$(jq --arg job $job '[ .status [] | select ( ."job-name" | startswith( $job ) ) ] | length' status/job-status.json)
  jq --argjson cells $cells --arg job $job '[ .status [] | select ( ."job-name" | startswith( $job ) ) | .memory.percent ] | map ( tonumber ) | add / $cells | floor' status/job-status.json > status/average_memory
}

scale_cells () {
  echo "Detemerming whether a change in capacity is needed (memory commited above $threshold% or below $(($threshold / 2))% on average)..."

  if [[ $cells -le $minimum_instance_count ]] ; then
    echo "Currently at minumum number of cell instances ($minimum_instance_count)."
    exit 
  fi

  change=

  if [[ "$(cat status/average_memory)" -gt $threshold ]] ; then
    change="up"
  elif [[ "$(cat status/average_memory)" -lt $(($threshold/2)) ]] ; then
    # always decrement by 1 to minimize impact
    increment=-1
    change="down"
  fi

  if [[ -n $change ]]; then
    new_cell_count=$(($cells + $increment))

    job_guid="$(
      om-linux \
        --target "$opsman_target" \
        --username "$opsman_user" \
        --password "$opsman_password" \
        --skip-ssl-validation \
        curl \
        --path /api/v0/staged/products/${product_guid}/jobs \
        --silent |
        jq --raw-output ".jobs[] | select ( .name == \"${job}\" ) | .guid"
    )"

    new_resource_config="$(
      om-linux \
        --target "$opsman_target" \
        --username "$opsman_user" \
        --password "$opsman_password" \
        --skip-ssl-validation \
        curl \
        --path /api/v0/staged/products/${product_guid}/jobs/${job_guid}/resource_config \
        --silent |
        jq --argjson cells $new_cell_count '.instances = $cells'
    )"

    echo "Scaling $change number of Diego cells ($job_guid) by ${increment#-} to $new_cell_count..."

    om-linux \
      --target "$opsman_target" \
      --username "$opsman_user" \
      --password "$opsman_password" \
      --skip-ssl-validation \
      curl \
      --path /api/v0/staged/products/${product_guid}/jobs/${job_guid}/resource_config \
      --request PUT \
      --data "${new_resource_config}" \
      --silent

    jq -n --argjson instances $new_cell_count '{ "instances": $instances }' > status/autoscale-instances.json
  fi
}

main () {
  get_status "cf"
  average_memory
  scale_cells
}

main
