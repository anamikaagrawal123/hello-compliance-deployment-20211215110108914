#!/usr/bin/env bash

#
# create cluster namespace
#
if kubectl get namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE"; then
  echo "Namespace ${IBMCLOUD_IKS_CLUSTER_NAMESPACE} found!"
else
  kubectl create namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE";
fi

deploy_count=0
overall_status=success

#
# iterate over inventory deployment delta
#
for INVENTORY_ENTRY in $(echo "${DEPLOYMENT_DELTA}" | jq -r '.[] '); do

  APP=$(cat "${INVENTORY_PATH}/${INVENTORY_ENTRY}")
  if [ -z "$(echo "${APP}" | jq -r '.name' 2> /dev/null)" ]; then continue ; fi # skip non artifact file

  APP_NAME=$(echo "${APP}" | jq -r '.name')
  ARTIFACT=$(echo "${APP}" | jq -r '.artifact')
  REGISTRY_URL="$(echo "${ARTIFACT}" | awk -F/ '{print $1}')"
  IMAGE="${ARTIFACT}"
  IMAGE_PULL_SECRET_NAME="ibmcloud-toolchain-${IBMCLOUD_TOOLCHAIN_ID}-${REGISTRY_URL}"

  #
  # create pull secrets for the image registry
  #
  if kubectl get secret -n "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" "$IMAGE_PULL_SECRET_NAME"; then
    echo "Image pull secret ${IMAGE_PULL_SECRET_NAME} found!"
  else
    if [[ "$BREAK_GLASS" == true ]]; then
      kubectl create -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $IMAGE_PULL_SECRET_NAME
  namespace: $IBMCLOUD_IKS_CLUSTER_NAMESPACE
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: $(jq .parameters.docker_config_json /config/artifactory)
EOF
    else
      kubectl create secret docker-registry \
        --namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" \
        --docker-server "$REGISTRY_URL" \
        --docker-password "$IBMCLOUD_API_KEY" \
        --docker-username iamapikey \
        --docker-email ibm@example.com \
        "$IMAGE_PULL_SECRET_NAME"
    fi
  fi

  if kubectl get serviceaccount -o json default --namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" | jq -e 'has("imagePullSecrets")'; then
    if kubectl get serviceaccount -o json default --namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" | jq --arg name "$IMAGE_PULL_SECRET_NAME" -e '.imagePullSecrets[] | select(.name == $name)'; then
      echo "Image pull secret $IMAGE_PULL_SECRET_NAME found in $IBMCLOUD_IKS_CLUSTER_NAMESPACE"
    else
      echo "Adding image pull secret $IMAGE_PULL_SECRET_NAME to $IBMCLOUD_IKS_CLUSTER_NAMESPACE"
      kubectl patch serviceaccount \
        --namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" \
        --type json \
        --patch '[{"op": "add", "path": "/imagePullSecrets/-", "value": {"name": "'"$IMAGE_PULL_SECRET_NAME"'"}}]' \
        default
    fi
  else
    echo "Adding image pull secret $IMAGE_PULL_SECRET_NAME to $IBMCLOUD_IKS_CLUSTER_NAMESPACE"
    kubectl patch serviceaccount \
      --namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" \
      --patch '{"imagePullSecrets":[{"name":"'"$IMAGE_PULL_SECRET_NAME"'"}]}' \
      default
  fi

  #
  # create "different" deployment yamls for deployed apps
  #
  cp deployment.yaml tmp-deployment.yaml
  NORMALIZED_APP_NAME=$(echo "${APP_NAME}" | sed 's/\//--/g')
  sed -i "s#hello-compliance-app#${NORMALIZED_APP_NAME}#g" tmp-deployment.yaml
  sed -i "s#hello-service#${NORMALIZED_APP_NAME}-service#g" tmp-deployment.yaml

  sed -i "s~^\([[:blank:]]*\)image:.*$~\1image: ${IMAGE}~" tmp-deployment.yaml

  deployment_name=$(yq r tmp-deployment.yaml metadata.name)
  service_name=$(yq r -d1 tmp-deployment.yaml metadata.name)

  #
  # deploy the app
  #
  kubectl apply --namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" -f tmp-deployment.yaml
  if kubectl rollout status --namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" "deployment/$deployment_name"; then
      status=success
      ((deploy_count+=1))
  else
      status=failure
  fi

  kubectl get events --sort-by=.metadata.creationTimestamp -n "$IBMCLOUD_IKS_CLUSTER_NAMESPACE"

  if [ "$status" == failure ]; then
      echo "Deployment failed"
      ibmcloud cr quota
      overall_status=failure
      break
  fi

  IP_ADDRESS=$(kubectl get nodes -o json | jq -r '[.items[] | .status.addresses[] | select(.type == "ExternalIP") | .address] | .[0]')
  PORT=$(kubectl get service -n  "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" "$service_name" -o json | jq -r '.spec.ports[0].nodePort')

  echo "Application URL: http://${IP_ADDRESS}:${PORT}"

  APP_URL_PATH="$(echo "${INVENTORY_ENTRY}" | sed 's/\//_/g')_app-url.json"

  echo -n "http://${IP_ADDRESS}:${PORT}" > "../$APP_URL_PATH"

done

echo "Deployed $deploy_count from $(echo "${DEPLOYMENT_DELTA}" | jq '. | length') entries"

if [ "$overall_status" == failure ]; then
    echo "Overall deployment failed"
    kubectl get events --sort-by=.metadata.creationTimestamp -n "$IBMCLOUD_IKS_CLUSTER_NAMESPACE"
    ibmcloud cr quota
    exit 1
fi

