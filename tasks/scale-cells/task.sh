#!/usr/bin/env bash

set -eu

product_guid=
cells=
reserved_memory=0
job=diego_cell
memory_per_cell=

gcp_credfile="status/gcpcreds.json"
cat > ${gcp_credfile} <<EOF
${gcp_credfile_contents}
EOF

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

get_cell_instance_memory () {
  echo "Determining cell vm total memory..."
  gcloud --project ${gcp_project} auth activate-service-account --key-file ${gcp_credfile}

  zone=$(jq --arg job $job '[ .status [] | select ( ."job-name" | startswith( $job ) ) | {cid , az_name} ][0]' status/job-status.json | jq -r .az_name)
  vm_name=$(jq --arg job $job '[ .status [] | select ( ."job-name" | startswith( $job ) ) | {cid , az_name} ][0]' status/job-status.json | jq -r .cid)

  memory_per_cell=$(( $(gcloud --project $gcp_project compute instances describe $vm_name --zone $zone --format='get(machineType)' | awk -F- '{print $NF}') ))
  echo "Memory per cell: $memory_per_cell MB"
}

average_memory () {
  echo "Determining number of cells..."
  cells=$(jq --arg job $job '[ .status [] | select ( ."job-name" | startswith( $job ) ) ] | length' status/job-status.json)
  # jq --argjson cells $cells --arg job $job '[ .status [] | select ( ."job-name" | startswith( $job ) ) | .memory.percent ] | map ( tonumber ) | add / $cells | floor' status/job-status.json > status/average_memory

  echo "Determining total reserved memory..."
  cf api $cf_api_uri --skip-ssl-validation
  cf auth $cf_username $cf_password

  cf curl "/v2/apps?results-per-page=10" > status/apps-1.json
  pages=$(jq '.total_pages' status/apps-1.json)

  for (( p=1; p<=$pages; p++))
  do
    cf curl "/v2/apps?order-direction=asc&page=$p&results-per-page=10" > status/apps-$p.json
    reserved_memory=$(($reserved_memory + $(jq '[ .resources [].entity | select ( .state=="STARTED" ) | .memory * .instances]' status/apps-$p.json |  jq 'add')))
  done

  echo "Determining average memory allocation percent - $cells cells with $(($memory_per_cell)) MB memory each, $reserved_memory MB of reserved memory..."
  echo $((100 * $reserved_memory / ($cells * $memory_per_cell))) > status/average_memory
}

scale_cells () {
  echo "Detemerming whether a change in capacity is needed (memory commited above $threshold% or below $(($threshold / 2))% on average)..."

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

    if [[ $new_cell_count -lt $minimum_instance_count ]] ; then
      echo "Currently at minumum number of cell instances ($minimum_instance_count)."
      exit
    fi

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
  get_cell_instance_memory
  average_memory
  scale_cells
}

main
