import os
import sys
import time
import secrets
import shutil
import subprocess

def write_header(msg):
    """Prints a bold, clean visual separator to stream to the console."""
    print(f"\n" + "="*70)
    print(f">>> {msg}")
    print("="*70 + "\n")
    sys.stdout.flush()

def run_command(command, shell=False):
    """Executes a command and streams its stdout/stderr live to the screen."""
    try:
        # Popen allows us to attach to stdout and read it line-by-line while it runs
        process = subprocess.Popen(
            command,
            shell=shell,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT
        )
        
        # Read the buffer stream continuously as chunks arrive
        while True:
            output = process.stdout.readline()
            if not output and process.poll() is not None:
                break
            if output:
                sys.stdout.buffer.write(output)
                sys.stdout.flush()
                
        rc = process.poll()
        if rc != 0:
            print(f"\n❌ Command failed with exit code {rc}", file=sys.stderr)
            sys.exit(rc)
    except Exception as e:
        print(f"\n❌ Execution Error occurred: {str(e)}", file=sys.stderr)
        sys.exit(1)

# --- Phase 1: Authentication and Context Mapping ---
write_header("Phase 1: Syncing EKS Cluster Kubeconfig Context...")
run_command(["aws", "eks", "update-kubeconfig", "--name", "bookstore-eks", "--region", "us-west-1"])

write_header("Verifying Master Cluster Node Connectivity...")
run_command(["kubectl", "get", "nodes"])

# --- Phase 2: Dynamic Storage Setup ---
write_header("Phase 2: Provisioning Dynamic AWS EBS CSI Add-on Engine...")
# run_command(["aws", "eks", "create-addon", "--cluster-name", "bookstore-eks", "--addon-name", "aws-ebs-csi-driver", "--region", "us-west-1", "--resolve-conflicts", "OVERWRITE"])

write_header("Awaiting Storage Plugin Activation...")
while True:
    # Query current status
    status_proc = subprocess.run(
        ["aws", "eks", "describe-addon", "--cluster-name", "bookstore-eks", "--addon-name", "aws-ebs-csi-driver", "--region", "us-west-1", "--query", "addon.status", "--output", "text"],
        capture_output=True, text=True
    )
    status = status_proc.stdout.strip()
    if status == "ACTIVE":
        print("✅ EBS CSI dynamic driver is officially ACTIVE!")
        break
    else:
        print(f"🔄 Add-on provisioning status: [{status}]... retrying in 10 seconds...")
        sys.stdout.flush()
        time.sleep(10)

write_header("Deploying Baseline gp3 StorageClass Resource Manifest...")
if os.path.exists("gp3-storageclass.yaml"):
    run_command(["kubectl", "apply", "-f", "gp3-storageclass.yaml"])
else:
    print("⚠️ gp3-storageclass.yaml not found, skipping...")

# --- Phase 3: Immediate Compute Optimization ---
write_header("Phase 3: Scaling Node Group to Pre-empt 'Too Many Pods' Threshold...")
run_command(["aws", "eks", "update-nodegroup-config", "--cluster-name", "bookstore-eks", "--nodegroup-name", "bookstore-node-group", "--scaling-config", "minSize=1,maxSize=4,desiredSize=2", "--region", "us-west-1"])

write_header("Pausing for 20 seconds to allow the secondary worker instance to join cluster...")
time.sleep(20)
run_command(["kubectl", "get", "nodes"])

# --- Phase 4: Platform Engine Provisioning via Helm ---
write_header("Phase 4: Registering and Synchronizing Helm Repositories...")
run_command(["helm", "repo", "add", "jetstack", "https://charts.jetstack.io"])
run_command(["helm", "repo", "add", "external-secrets", "https://charts.external-secrets.io"])
run_command(["helm", "repo", "add", "ingress-nginx", "https://kubernetes.github.io/ingress-nginx"])
run_command(["helm", "repo", "update"])

write_header("Deploying Cryptographic Cert-Manager Sub-plane...")
run_command(["helm", "install", "cert-manager", "jetstack/cert-manager", "--namespace", "cert-manager", "--create-namespace", "--version", "v1.14.4", "--set", "installCRDs=true"])
run_command(["kubectl", "wait", "pods", "-n", "cert-manager", "--all", "--for=condition=Ready", "--timeout=120s"])

write_header("Applying Production Let's Encrypt Certificate ClusterIssuer...")
if os.path.exists("cluster-issuer.yaml"):
    run_command(["kubectl", "apply", "-f", "cluster-issuer.yaml"])
else:
    print("⚠️ cluster-issuer.yaml not found, skipping...")

write_header("Deploying External Secrets Operator Architecture...")
run_command(["helm", "install", "external-secrets", "external-secrets/external-secrets", "--namespace", "external-secrets", "--create-namespace", "--set", "installCRDs=true"])
run_command(["kubectl", "wait", "pods", "-n", "external-secrets", "--all", "--for=condition=Ready", "--timeout=120s"])

write_header("Wiping Local Kubectl Discovery Cache and Establishing ClusterSecretStore...")
# Clear the cache to prevent schema lookup conflicts
cache_path = os.path.expandvars(r"%USERPROFILE%\.kube\cache")
if os.path.exists(cache_path):
    shutil.rmtree(cache_path, ignore_errors=True)

if os.path.exists("cluster-secret-store.yaml"):
    run_command(["kubectl", "apply", "-f", "cluster-secret-store.yaml"])
else:
    print("⚠️ cluster-secret-store.yaml not found, skipping...")

write_header("Deploying Ingress NGINX Gateway LoadBalancer...")
run_command(["helm", "install", "ingress-nginx", "ingress-nginx/ingress-nginx", "--namespace", "ingress-nginx", "--create-namespace"])
time.sleep(15)
run_command(["kubectl", "get", "svc", "-n", "ingress-nginx"])

# --- Phase 5: GitOps Control Plane Setup ---
write_header("Phase 5: Instantiating GitOps Delivery Architecture (ArgoCD)...")
# Server-side apply to completely bypass client annotation size limits
run_command(["kubectl", "create", "namespace", "argocd"], shell=True) # allow graceful error if exists
run_command(["kubectl", "apply", "-n", "argocd", "-f", "https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml", "--server-side"])

write_header("Patching Missing Core Security Layer (server.secretkey)...")
generated_key = secrets.token_hex(32)
# Windows Shell escaped formatting for clean JSON parsing
patch_string = f'{{"stringData": {{"server.secretkey": "{generated_key}"}}}}'
run_command(["kubectl", "-n", "argocd", "patch", "secret", "argocd-secret", "-p", patch_string])

write_header("Registering the Core 3-Tier Application Root Spec...")
if os.path.exists("k8s/argocd/application.yaml"):
    run_command(["kubectl", "apply", "-f", "k8s/argocd/application.yaml"])
else:
    print("⚠️ k8s/argocd/application.yaml not found, skipping...")

write_header("Triggering Controller Deployment Recycling Loop...")
run_command(["kubectl", "rollout", "restart", "deployment/argocd-dex-server", "-n", "argocd"])
run_command(["kubectl", "rollout", "restart", "deployment/argocd-applicationset-controller", "-n", "argocd"])

write_header("Unifying GitOps Target Synchronization Point to Branch: main...")
time.sleep(5)
target_revision_patch = '{"spec":{"source":{"targetRevision":"main"}}}'
run_command(["kubectl", "patch", "application", "bookstore", "-n", "argocd", "--type", "merge", "-p", target_revision_patch])
run_command(["kubectl", "annotate", "application", "bookstore", "-n", "argocd", "argocd.argoproj.io/refresh=hard", "--overwrite"])

write_header("Bootstrap Complete! Fetching Running Control Plane Workloads Map...")
time.sleep(5)
run_command(["kubectl", "get", "pods", "-n", "argocd"])

print("\n🎉 [SUCCESS] All EKS cluster platform tools have been successfully bootstrapped via Python GitOps automation!")