# ssc-demo

This project contains a demo showing automated remediation of application CVEs.  

The demo includes analysis of an example containerized Java project to find vulnerable CVEs and recommend a fix for each; automated creation of issue tracker work items for each CVE; automated CVE remediation; automated regression test generation; automated gitops promotion to dev, qa, and production environments.  

Patched CVE packages are sourced both from Red Hat Lightwell (https://www.redhat.com/en/lightwell) and upstream (Maven Central).    

The Red Hat Lightwell public demo repositories used include:   

| Repository | URL |  
| Java Validated | https://packages.redhat.com/lightwell/public-lightwell-demo/java/validated/ |    
| Java Remediated | https://packages.redhat.com/lightwell/public-lightwell-demo/java/remediated/ |    
| Java OSV Advisories | https://packages.redhat.com/api/pulp-content/public-lightwell-demo/osv/java/remediated/ |   


# Setup Guide  

Refer to the [runbook](automation/gitops/RUNBOOK.md)
