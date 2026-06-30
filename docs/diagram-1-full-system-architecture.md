```mermaid
graph TD
    %%----------------------------------------------------------------------
    %% LAYER 1: EXTERNAL / INTERNET
    %%----------------------------------------------------------------------
    subgraph "LAYER 1: External / Internet"
        direction LR
        User(["User Browser"])
        Registrar(["Domain Registrar"])
    end

    %%----------------------------------------------------------------------
    %% LAYER 4: GITHUB (EXTERNAL)
    %%----------------------------------------------------------------------
    subgraph "LAYER 4: GitHub"
        direction TB
        GitHub_Repo["GitHub Repo (Source of Truth)"]
        GitHub_Actions["GitHub Actions (CI/CD)"]
        GitHub_OIDC["OIDC Trust<br>(GitHub Actions to AWS IAM)"]
    end

    %%----------------------------------------------------------------------
    %% AWS ACCOUNT
    %%----------------------------------------------------------------------
    subgraph "AWS Account (us-west-1 / N. California)"
        direction TB

        %%------------------------------------------------------------------
        %% LAYER 3: AWS MANAGED SERVICES (Outside VPC)
        %%------------------------------------------------------------------
        subgraph "LAYER 3: AWS Managed Services"
            direction RL
            ECR["ECR<br>(bookstore-frontend, bookstore-backend)"]
            SecretsManager["Secrets Manager<br>(/bookstore/db-credentials, /bookstore/grafana-admin)"]
            ACM["ACM<br>(Certificate for *.b17facebook.xyz)"]
            CloudTrail["CloudTrail<br>(Logs to Encrypted S3)"]
            GuardDuty["GuardDuty<br>(EKS, S3, Malware Scans)"]
            S3_Terraform["S3 Bucket<br>(Terraform Remote State)"]
            DynamoDB_Lock["DynamoDB<br>(Terraform State Lock)"]
        end

        %%------------------------------------------------------------------
        %% ENTRY POINTS (Route53 / CloudFront)
        %%------------------------------------------------------------------
        subgraph "Public Entry"
            direction LR
            style PublicEntry fill:none,stroke:none
            Route53["Route 53<br>(b17facebook.xyz)<br>Active/Passive Health Check"]
            CloudFront["CloudFront CDN<br>(Optional: enable_cloudfront=true)"]
        end

        %%------------------------------------------------------------------
        %% LAYER 2: VPC
        %%------------------------------------------------------------------
        subgraph "LAYER 2: VPC (170.20.0.0/16)"
            IGW["Internet Gateway"]
            VPC_Flow_Logs["VPC Flow Logs<br>(To CloudWatch, 90-day retention)"]
            IGW---VPC_Flow_Logs

            %% PUBLIC SUBNETS
            subgraph "Public Subnets (us-west-1a, us-west-1c)"
                direction LR
                NAT_GW["NAT Gateway<br>(in us-west-1a)<br>Note: Single GW for cost"]
                NLB["AWS Network Load Balancer (NLB)<br>Provisioned by Ingress Controller"]
            end

            %% PRIVATE SUBNETS - EKS
            subgraph "Private Subnets: EKS Node Group (t3.medium, 2 AZs)"
                EKS_Node_Group["EKS Nodes"]
                subgraph "Kubernetes Pods (Example on one Node)"
                    direction TB
                    %% Bookstore Namespace
                    subgraph "namespace: bookstore (blue)"
                        style bookstore fill:#eaf2fa,stroke:#2c7be5
                        Frontend_Pod["Pod: frontend (React/Nginx)<br>Port: 8080 | Replicas: 2 | HPA: 2-3"]
                        Backend_Pod["Pod: backend (Node.js/Express)<br>Port: 3000 | Argo Rollout | HPA: 1-5<br>Provides /metrics endpoint"]
                    end
                    %% Ingress-Nginx Namespace
                    subgraph "namespace: ingress-nginx (orange)"
                        style ingress-nginx fill:#fdece1,stroke:#f58025
                        Ingress_Controller["Pod: ingress-nginx controller"]
                    end
                    %% Cert-Manager Namespace
                    subgraph "namespace: cert-manager (purple)"
                        style cert-manager fill:#f4e8f7,stroke:#a456b8
                        Cert_Manager["Pod: cert-manager controller"]
                        ClusterIssuer["ClusterIssuer: letsencrypt-prod<br>(ACME HTTP-01 Solver)"]
                    end
                    %% External-Secrets Namespace
                    subgraph "namespace: external-secrets (yellow)"
                        style external-secrets fill:#fff9e6,stroke:#ffbf00
                        ESO_Controller["Pod: External Secrets Operator"]
                        ClusterSecretStore["ClusterSecretStore<br>(Uses IRSA Role)"]
                    end
                    %% Monitoring Namespace
                    subgraph "namespace: monitoring (green)"
                        style monitoring fill:#e6f5e6,stroke:#34a853
                        Prometheus["Prometheus"]
                        Grafana["Grafana"]
                        Alertmanager["Alertmanager"]
                        Loki["Loki & Promtail (DaemonSet)"]
                    end
                    %% GitOps Namespaces
                    subgraph "namespace: argocd (teal)"
                        style argocd fill:#e0f5f5,stroke:#00a2a2
                        ArgoCD_Server["ArgoCD Server"]
                    end
                    subgraph "namespace: argo-rollouts (red)"
                        style argo-rollouts fill:#fce8e6,stroke:#ea4335
                        Argo_Rollouts_Controller["Argo Rollouts Controller"]
                    end
                end
            end

            %% PRIVATE SUBNETS - RDS
            subgraph "Private Subnets: RDS (us-west-1a, us-west-1c)"
                RDS_Primary["RDS MySQL 8.0 Primary<br>(db.t3.micro)"]
                RDS_Standby["RDS MySQL Standby"]
                RDS_Primary---RDS_Standby---RDS_Primary
                RDS_Logs["CloudWatch Logs<br>(error, general, slowquery)<br>Perf. Insights, Enhanced Mon."]
                RDS_Primary---RDS_Logs
            end

            %% SECURITY
            subgraph "Security Controls"
                style Security Controls fill:none,stroke:#000
                SG_NLB["SG: NLB<br>(Allow 443/80 from Internet)"]
                SG_EKS["SG: EKS Nodes"]
                SG_RDS["SG: RDS<br>(Allow 3306 from EKS SG)"]
                NetPol["NetworkPolicy<br>(Default Deny in bookstore ns)"]
            end
        end
    end

    %%======================================================================
    %% CONNECTIONS
    %%======================================================================

    %% External User Flow
    User --"HTTPS"--> Route53
    Registrar --"NS Records"--> Route53
    Route53 --"DNS Resolution"--> NLB
    User -.->|"Optional"| CloudFront
    CloudFront -.->|"Caches Origin"| NLB

    %% VPC Traffic Flow
    NLB <--> IGW
    NLB -- "Port 443/80" --> Ingress_Controller
    Ingress_Controller -- "route: bookstore.b17facebook.xyz" --> Frontend_Pod
    Ingress_Controller -- "route: /api/*" --> Backend_Pod
    Backend_Pod -- "Port 3306" --> RDS_Primary
    EKS_Node_Group -- "Outbound Traffic" --> NAT_GW
    NAT_GW --> IGW

    %% CI/CD and GitOps Flow
    GitHub_Actions --"1. Push Docker Image"--> ECR
    GitHub_Actions --"2. Update Image Tag in kustomization.yaml"--> GitHub_Repo
    GitHub_Actions --"Uses OIDC"--> GitHub_OIDC
    ArgoCD_Server --"3. Polls Repo (every 3 min)"--> GitHub_Repo
    ArgoCD_Server --"4. Applies Manifests"--> Argo_Rollouts_Controller
    Argo_Rollouts_Controller --"Manages"--> Backend_Pod
    Argo_Rollouts_Controller --"Updates Canary Weight Annotation"--> Ingress_Controller
    EKS_Node_Group --"Pulls Image"--> ECR

    %% Secrets Management Flow
    ESO_Controller -- "Uses IRSA to assume IAM Role" --> SecretsManager
    ESO_Controller --"Syncs Secret"--> ClusterSecretStore
    ESO_Controller --"Creates k8s 'db-secret'"--> K8S_DB_Secret(("[k8s Secret]"))
    K8S_DB_Secret --"Mounted as Env Vars"--> Backend_Pod

    %% TLS/Cert Management Flow
    Cert_Manager --"Watches Ingress Objects"--> Ingress_Controller
    Cert_Manager --"Solves ACME Challenge"--> ClusterIssuer
    ClusterIssuer --"Gets Cert from Let's Encrypt"--> LE(("[Let's Encrypt]"))
    Cert_Manager --"Stores as k8s Secret"--> K8S_TLS_Secret(("[k8s Secret]"))
    K8S_TLS_Secret --"TLS Termination"--> Ingress_Controller
    NLB --"TLS Passthrough"--> Ingress_Controller
    ACM -- "Provides Cert for NLB (Alternative)"--> NLB


    %% Monitoring & Observability Flow
    Prometheus --"Scrapes /metrics"--> Backend_Pod
    Prometheus --"Feeds Canary Analysis"--> Argo_Rollouts_Controller
    Loki --"Collects Pod Logs"--> EKS_Node_Group
    Grafana --"Queries"--> Prometheus
    Grafana --"Queries"--> Loki
    Grafana --"Admin Password from"--> SecretsManager

    %% Security Group Connections
    NLB---SG_NLB
    EKS_Node_Group---SG_EKS
    RDS_Primary---SG_RDS
    SG_EKS-->SG_RDS

end
```

To render this diagram, you can use a Markdown viewer that supports Mermaid, such as the one on GitHub, or a dedicated online editor like the Mermaid Live Editor.
