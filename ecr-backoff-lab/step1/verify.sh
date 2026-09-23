#!/bin/bash
NS=payments
IMG=123456789012.dkr.ecr.us-east-1.amazonaws.com/payments-api:1.4.2
TOKEN=$(cat /opt/mock-ecr/.token)

# image and pull policy unchanged (local-cache shortcuts don't count)
[ "$(kubectl get deploy payments-api -n $NS -o jsonpath='{.spec.template.spec.containers[0].image}')" = "$IMG" ] || exit 1
[ "$(kubectl get deploy payments-api -n $NS -o jsonpath='{.spec.template.spec.containers[0].imagePullPolicy}')" = "Always" ] || exit 1

# the referenced secret holds the valid credential
SECRET=$(kubectl get deploy payments-api -n $NS -o jsonpath='{.spec.template.spec.imagePullSecrets[0].name}')
[ -z "$SECRET" ] && SECRET=$(kubectl get sa default -n $NS -o jsonpath='{.imagePullSecrets[0].name}')
[ -z "$SECRET" ] && exit 1
CFG=$(kubectl get secret "$SECRET" -n $NS -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)
AUTH=$(echo -n "AWS:${TOKEN}" | base64 | tr -d '\n')
echo "$CFG" | grep -q -e "$TOKEN" -e "$AUTH" || exit 1

# 2 replicas available
[ "$(kubectl get deploy payments-api -n $NS -o jsonpath='{.status.availableReplicas}')" = "2" ]
