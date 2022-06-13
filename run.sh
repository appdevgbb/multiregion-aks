# *nix only
export prefix="multiregionaks"
export RG="rg-${prefix}"
export LOC_1="eastus"
export LOC_2="westus2"
export SUB_ID="<YourSubscriptionID>"

# Follow Azure CLI prompts to authenticate to the subscription of your choice
az login
az account set --subscription $SUB_ID

# Create resource group
az group create -n $RG -l $LOC_1

# Deploy region-specific resources in region one: AKS cluster, Log Analytics workspace, VNet, Managed identity
az deployment group validate -f ./deploy/region1.bicep -g  $RG --parameters ./deploy/region1.params.json --parameters rgName=$RG location=$LOC_1 prefix=$prefix
az deployment group create -f ./deploy/region1.bicep -g  $RG --parameters ./deploy/region1.params.json --parameters rgName=$RG location=$LOC_1 prefix=$prefix

# Repeat for second region
# TODO

# Display outputs from bicep deployment
az deployment group show -n region1  -g $RG --query properties.outputs

# Deploy Nginx ingress controller with internal LB: https://docs.microsoft.com/en-us/azure/aks/ingress-internal-ip?tabs=azure-cli
CLUSTER_NAME=$(az deployment group show -n region1  -g $RG --query properties.outputs.aksClusterName.value -o tsv)
az aks get-credentials -n $CLUSTER_NAME -g $RG

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install nginx-ingress ingress-nginx/ingress-nginx \
    --namespace ingress-basic --create-namespace \
    --set controller.replicaCount=2 \
    --set controller.nodeSelector."kubernetes\.io/os"=linux \
    --set defaultBackend.nodeSelector."kubernetes\.io/os"=linux \
    --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
    -f ./deploy/manifests/internal-ingress.yaml

# Wait until "External" IP (internal to VNet) address is assigned (10.240.4.4 for Region One)
kubectl --namespace ingress-basic get services -o wide -w nginx-ingress-ingress-nginx-controller

# Deploy apps and ingress on cluster
kubectl apply -f ./deploy/manifests/app-one.yaml --namespace ingress-basic
kubectl apply -f ./deploy/manifests/app-two.yaml --namespace ingress-basic
kubectl get pods -n ingress-basic
kubectl apply -f ./deploy/manifests/ingress.yaml --namespace ingress-basic
kubectl get ingress -n ingress-basic 

# Ensure ingress and app configuration works
kubectl run -it --rm aks-ingress-test --image=mcr.microsoft.com/dotnet/runtime-deps:6.0 --namespace ingress-basic
# Run the following inside container shell
apt-get update && apt-get install -y curl
curl -L http://10.240.4.4  # Should receive "Ingress Route One: Region One" HTML page
curl -L http://10.240.4.4/ingress-two # Should receive "Ingress Route Two: Region One" HTML page
# Exit container shell

# get IP configuration of cluster ILB that was created for the ingress controller
NODEPOOL_RG=$(az aks show -g $RG -n $CLUSTER_NAME --query 'nodeResourceGroup' -o tsv)
LB_IP_CONFIG=$(az network lb frontend-ip list  --lb-name  kubernetes-internal -g $NODEPOOL_RG -o tsv --query "[].id") 

# Deploy Front Door configured with  WAF, Private DNS and a Private Link Service to attach to AKS cluster
az deployment group validate -f ./deploy/afd.bicep -g  $RG --parameters ./deploy/afd.params.json --parameters prefix=$prefix loadBalancerFrontendIpConfigurationResourceId=$LB_IP_CONFIG
az deployment group create -f ./deploy/afd.bicep -g  $RG --parameters ./deploy/afd.params.json --parameters prefix=$prefix loadBalancerFrontendIpConfigurationResourceId=$LB_IP_CONFIG 

# Approve the Private Endpoints to enable AFD with Private Link
# Should there be two Private IPs here?
PRIVATE_EP_ID=$(az network private-link-service list -g $RG --query "[].privateEndpointConnections[0].id" -o tsv)
az network private-endpoint-connection approve --id $PRIVATE_EP_ID --description "Approved"

# Vist the following url to view your multi-region aks setup!
az deployment group show -n afd  -g $RG --query properties.outputs.frontDoorEndpointHostName.value -o tsv   



