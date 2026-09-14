# ssc-demo

Pre-requisite infrastructure setup adapted from:  
https://github.com/rhpds/lightwell-tssc-workshop  

Before proceeding to pipelines setup (/pipelines), install and configure:  
* OpenShift GitOps  
* OpenShift KeyCloak  
* Red Hat Trusted Profile Analyzer
* Red Hat Trusted Artifact Signer
* GitLab  


# OpenShift Cluster Resource Requirements  

| Role | Minimum CPU (Cores) | Minimum RAM (GiB) | Recommended CPU (Cores) | Recommended RAM (GiB) |  
| --- | --- | --- | --- | --- |  
| Control plane | 4 per node | 16 per node | 8 per node | 32 per node |  
| Worker | 5 per node | 17 per node | 8 per node | 24 per node |  
  

Source:  
https://docs.redhat.com/en/documentation/red_hat_advanced_developer_suite_-_software_supply_chain/1.9/html-single/installing_red_hat_advanced_developer_suite_-_software_supply_chain/index#minimum-hardware-requirements_installing-rhads


# Setup Guide  
