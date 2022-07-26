# *nix only
export prefix="multiregionaks"
export RG="rg-${prefix}"
export LOC_1="eastus" # AFD Private Link supported regions: https://docs.microsoft.com/en-us/azure/frontdoor/private-link#region-availability
export LOC_2="westus3"
export REGION_NUMS=("region1" "region2")
export REGION_NUM_IPS=("10.240.4.4" "10.240.4.5")
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
az deployment group validate -f ./deploy/region2.bicep -g  $RG --parameters ./deploy/region2.params.json --parameters rgName=$RG location=$LOC_2 prefix=$prefix
az deployment group create -f ./deploy/region2.bicep -g  $RG --parameters ./deploy/region2.params.json --parameters rgName=$RG location=$LOC_2 prefix=$prefix

# Display outputs from bicep deployment
az deployment group show -n region1  -g $RG --query properties.outputs
az deployment group show -n region2  -g $RG --query properties.outputs

##########
#### Note: the following must be repeated for each cluster. Change the variables below to reference the regional kustomizations.
##########
export REGION_NUM=$REGION_NUMS[1]
export REGION_NUM_IP=$REGION_NUM_IPS[1]

# Deploy Nginx ingress controller with internal LB: https://docs.microsoft.com/en-us/azure/aks/ingress-internal-ip?tabs=azure-cli
CLUSTER_NAME=$(az deployment group show -n $REGION_NUM -g $RG --query properties.outputs.aksClusterName.value -o tsv)
az aks get-credentials -n $CLUSTER_NAME -g $RG

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install nginx-ingress ingress-nginx/ingress-nginx \
    --namespace ingress-basic --create-namespace \
    --set controller.replicaCount=2 \
    --set controller.nodeSelector."kubernetes\.io/os"=linux \
    --set defaultBackend.nodeSelector."kubernetes\.io/os"=linux \
    --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
    -f ./deploy/manifests/internal-ingress-$REGION_NUM.yaml

# Wait until "External" IP (internal to VNet) address is assigned
kubectl --namespace ingress-basic get services -o wide -w nginx-ingress-ingress-nginx-controller

# Deploy apps and ingress on cluster with kustomizations
kubectl apply -k deploy/manifests/overlays/$REGION_NUM --namespace ingress-basic
kubectl get pods -n ingress-basic

# Ensure ingress and app configuration works
kubectl run -it --rm aks-ingress-test --image=mcr.microsoft.com/dotnet/runtime-deps:6.0 --namespace ingress-basic
# Run the following inside container shell
apt-get update && apt-get install -y curl 
curl -L http://$REGION_NUM_IP # Should receive "Region One/Two: Ingress Route One" HTML page
curl -L http://$REGION_NUM_IP/ingress-two # Should receive "Region One/Two: Ingress Route Two" HTML page
# Exit container shell

##########
#### Note: Only after both clusters and apps are deployed, deploy the following AFD configuration
##########

# get IP configuration of cluster ILB that was created for the ingress controller
LB_IP_CONFIG=()
for r in $REGION_NUMS
do
    echo $r
    CLUSTER_NAME=$(az deployment group show -n $r -g $RG --query properties.outputs.aksClusterName.value -o tsv)
    NODEPOOL_RG=$(az aks show -g $RG -n $CLUSTER_NAME --query 'nodeResourceGroup' -o tsv)
    LB_IP_CONFIG+=$(az network lb frontend-ip list  --lb-name  kubernetes-internal -g $NODEPOOL_RG -o tsv --query "[].id")
done

# Deploy Front Door configured with  WAF, Private DNS and a Private Link Service to attach to AKS cluster
az deployment group validate -f ./deploy/afd.bicep -g  $RG --parameters ./deploy/afd.params.json --parameters prefix=$prefix lbFrontendIpConfigId1=${LB_IP_CONFIG[1]} lbFrontendIpConfigId2=${LB_IP_CONFIG[2]}
az deployment group create -f ./deploy/afd.bicep -g  $RG --parameters ./deploy/afd.params.json --parameters prefix=$prefix  lbFrontendIpConfigId1=${LB_IP_CONFIG[1]} lbFrontendIpConfigId2=${LB_IP_CONFIG[2]}

# Approve the Private Endpoints to enable AFD with Private Link
for r in $REGION_NUMS
do
    echo $r
    PRIVATE_EP_ID=$(az network private-link-service list -g $RG --query "[?contains(name,'$r')].privateEndpointConnections[0].id" -o tsv)
    az network private-endpoint-connection approve --id $PRIVATE_EP_ID --description "Approved"
done

# Navigate to the following url to view your multi-region aks setup! 
az deployment group show -n afd  -g $RG --query properties.outputs.frontDoorEndpointHostName.value -o tsv   

# Note: For deletion, ensure you delete the Virtual Network links in Private DNS Zone first, then resouce group with remaining resources