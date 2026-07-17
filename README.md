# JWKS Hosting — Terraform

This Terraform configuration provisions AWS infrastructure to host JWKS (JSON Web Key Sets) files for one or more applications. It creates a **private S3 bucket** in `ca-central-1` (Montreal) and exposes the files via a **CloudFront distribution** over HTTPS, with caching disabled so consumers always receive the latest keys.

## Architecture

```
Local jwks.json files → S3 Bucket (ca-central-1, private)
                              ↓ (OAC / SigV4)
                       CloudFront Distribution
                              ↓ (HTTPS only)
              https://<cf-domain>/<app>/.well-known/jwks
```

## Prerequisites

| Tool | Minimum Version | Install |
|------|----------------|---------|
| [Terraform](https://developer.hashicorp.com/terraform/downloads) | 1.0.0 | See below |
| [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | 2.x | See below |
| AWS credentials with permissions to manage S3, CloudFront, and IAM policies | — | See below |

---

## Installation

### Mac

```bash
# Install Homebrew if not already installed
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install Terraform and AWS CLI
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
brew install awscli
```

### Windows

Using [Chocolatey](https://chocolatey.org/install) (run in an elevated PowerShell prompt):

```powershell
choco install terraform -y
choco install awscli -y
```

Or download and install manually:
- **Terraform**: https://developer.hashicorp.com/terraform/downloads
- **AWS CLI**: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html

---

## AWS Credentials Setup

### Option A — Standard (`aws configure`)

Configure your AWS credentials before running Terraform:

```bash
aws configure
```

You will be prompted for:
- **AWS Access Key ID**
- **AWS Secret Access Key**
- **Default region**: `ca-central-1`
- **Default output format**: `json`

Alternatively, export credentials as environment variables:

**Mac / Linux**
```bash
export AWS_ACCESS_KEY_ID="your-access-key-id"
export AWS_SECRET_ACCESS_KEY="your-secret-access-key"
export AWS_DEFAULT_REGION="ca-central-1"
```

**Windows (PowerShell)**
```powershell
$env:AWS_ACCESS_KEY_ID = "your-access-key-id"
$env:AWS_SECRET_ACCESS_KEY = "your-secret-access-key"
$env:AWS_DEFAULT_REGION = "ca-central-1"
```

---

### Option B — AWS Secrets Manager (Recommended)

Storing long-lived credentials in `~/.aws/credentials` or shell profiles is a security risk. A safer approach is to store the deployment credentials in **AWS Secrets Manager** and retrieve them at runtime, so they are never written to disk in plaintext.

The setup involves two separate IAM users:

| User | Purpose | Permissions needed |
|------|---------|-------------------|
| **Bootstrap user** | Stores and retrieves secrets from Secrets Manager | `secretsmanager` only |
| **Deployment user** | Runs Terraform to create AWS resources | S3, CloudFront, IAM |

The bootstrap user's credentials live in your local AWS CLI profile. The deployment user's credentials are stored *inside* Secrets Manager, retrieved at runtime, and never saved to disk.

---

#### Step 0 — Set up the Bootstrap IAM User

This is a one-time setup. The bootstrap user is a limited-privilege AWS account that can only interact with Secrets Manager — it cannot create or destroy any infrastructure.

##### 0a. Sign in to the AWS Console

1. Go to [https://console.aws.amazon.com](https://console.aws.amazon.com) and sign in with your root account or an existing admin account.
2. In the top-right corner, confirm the region is set to **Canada (Central) — ca-central-1**.

##### 0b. Create the Bootstrap IAM User

1. In the search bar at the top, type **IAM** and click the **IAM** service.
2. In the left sidebar, click **Users**, then click the **Create user** button.
3. Enter a username, e.g. `terraform-bootstrap`, then click **Next**.
4. On the "Set permissions" page, select **Attach policies directly**.
5. Do **not** attach any AWS managed policies. Click **Next**, then **Create user**.

> The bootstrap user starts with zero permissions. You will attach a custom policy in the next step.

##### 0c. Attach a Custom Secrets Manager Policy

1. Back on the **Users** list, click the `terraform-bootstrap` user you just created.
2. Click the **Add permissions** button, then choose **Create inline policy**.
3. Click the **JSON** tab and replace the existing content with the following policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowSecretsManagerAccess",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:CreateSecret",
        "secretsmanager:PutSecretValue",
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "arn:aws:secretsmanager:ca-central-1:*:secret:terraform/jwks-hosting/*"
    }
  ]
}
```

4. Click **Next**, give the policy a name such as `SecretsManagerJwksAccess`, then click **Create policy**.

##### 0d. Create Access Keys for the Bootstrap User

1. On the `terraform-bootstrap` user page, click the **Security credentials** tab.
2. Scroll down to **Access keys** and click **Create access key**.
3. Select **Command Line Interface (CLI)** as the use case, tick the confirmation checkbox, then click **Next**.
4. Click **Create access key**.
5. You will see both the **Access key ID** and **Secret access key** on screen.

> **Important:** This is the only time the secret access key is shown. Copy both values somewhere safe (e.g. a temporary note) before closing this page.

6. Click **Done**.

##### 0e. Configure the Bootstrap AWS CLI Profile

Run the following command in your terminal. This saves the bootstrap credentials as a **named profile** called `bootstrap` — completely separate from any default profile you may already have.

**Mac / Linux**
```bash
aws configure --profile bootstrap
```

**Windows (PowerShell)**
```powershell
aws configure --profile bootstrap
```

When prompted, enter the values from step 0d:

```
AWS Access Key ID [None]: AKIA...          ← paste your Access key ID
AWS Secret Access Key [None]: ...          ← paste your Secret access key
Default region name [None]: ca-central-1
Default output format [None]: json
```

##### 0f. Verify the Bootstrap Profile Works

```bash
aws sts get-caller-identity --profile bootstrap
```

Expected output (values will match your account):

```json
{
    "UserId": "AIDA...",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/terraform-bootstrap"
}
```

If you see this, your bootstrap profile is configured correctly and you can proceed.

---

#### Step 1 — Create the Deployment IAM User

The deployment user is the account that Terraform uses to actually create AWS resources. Its credentials will be stored securely inside Secrets Manager.

1. In the AWS Console, go to **IAM → Users → Create user**.
2. Enter a username such as `terraform-deployer`, then click **Next**.
3. On the "Set permissions" page, select **Attach policies directly**.
4. Search for and attach the following AWS managed policies:
   - `AmazonS3FullAccess`
   - `CloudFrontFullAccess`
5. Click **Next**, then **Create user**.

> For production environments, replace these broad managed policies with a narrower custom policy scoped to only the resources this project creates.

6. Click into the `terraform-deployer` user → **Security credentials** tab → **Create access key**.
7. Select **Command Line Interface (CLI)**, tick the checkbox, click **Next**, then **Create access key**.
8. Copy both the **Access key ID** and **Secret access key** — you will use them in the next step.
9. Click **Done**.

---

#### Step 2 — Store the Deployment Credentials in Secrets Manager

Now use the bootstrap profile to store the deployment user's credentials in Secrets Manager. Replace the placeholder values with the keys from Step 1.

**Mac / Linux**
```bash
aws secretsmanager create-secret \
  --name "terraform/jwks-hosting/credentials" \
  --description "Deployment credentials for JWKS hosting Terraform" \
  --secret-string '{
    "AWS_ACCESS_KEY_ID": "AKIA...",
    "AWS_SECRET_ACCESS_KEY": "your-secret-access-key"
  }' \
  --region ca-central-1 \
  --profile bootstrap
```

**Windows (PowerShell)**
```powershell
aws secretsmanager create-secret `
  --name "terraform/jwks-hosting/credentials" `
  --description "Deployment credentials for JWKS hosting Terraform" `
  --secret-string '{\"AWS_ACCESS_KEY_ID\":\"AKIA...\",\"AWS_SECRET_ACCESS_KEY\":\"your-secret-access-key\"}' `
  --region ca-central-1 `
  --profile bootstrap
```

You can now safely discard the plaintext copy of the deployment credentials.

To update the secret in the future (e.g. after rotating keys):

**Mac / Linux**
```bash
aws secretsmanager put-secret-value \
  --secret-id "terraform/jwks-hosting/credentials" \
  --secret-string '{
    "AWS_ACCESS_KEY_ID": "AKIA...",
    "AWS_SECRET_ACCESS_KEY": "your-updated-secret-key"
  }' \
  --region ca-central-1 \
  --profile bootstrap
```

---

#### Step 3 — Install `jq` (JSON parser)

**Mac**
```bash
brew install jq
```

**Windows (PowerShell — Chocolatey)**
```powershell
choco install jq -y
```

---

#### Step 4 — Retrieve Credentials and Run Terraform

Each time you want to run Terraform, use the bootstrap profile to pull the deployment credentials from Secrets Manager into environment variables for the current terminal session. Nothing is written to disk.

**Mac / Linux**
```bash
# Retrieve the secret using the bootstrap profile
SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "terraform/jwks-hosting/credentials" \
  --region ca-central-1 \
  --query SecretString \
  --output text \
  --profile bootstrap)

# Export as environment variables for Terraform
export AWS_ACCESS_KEY_ID=$(echo "$SECRET" | jq -r '.AWS_ACCESS_KEY_ID')
export AWS_SECRET_ACCESS_KEY=$(echo "$SECRET" | jq -r '.AWS_SECRET_ACCESS_KEY')
export AWS_DEFAULT_REGION="ca-central-1"

# Run Terraform (recommended: save plan to file for safety)
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

**Windows (PowerShell)**
```powershell
# Retrieve the secret using the bootstrap profile
$Secret = aws secretsmanager get-secret-value `
  --secret-id "terraform/jwks-hosting/credentials" `
  --region ca-central-1 `
  --query SecretString `
  --output text `
  --profile bootstrap | ConvertFrom-Json

# Export as environment variables for Terraform
$env:AWS_ACCESS_KEY_ID     = $Secret.AWS_ACCESS_KEY_ID
$env:AWS_SECRET_ACCESS_KEY = $Secret.AWS_SECRET_ACCESS_KEY
$env:AWS_DEFAULT_REGION    = "ca-central-1"

# Run Terraform (recommended: save plan to file for safety)
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

> **Tip:** These environment variables are scoped to the current terminal session only. Close the terminal when done and the credentials disappear from memory.

---

### Option C — AWS CloudShell (Most Secure)

AWS CloudShell runs a terminal directly inside the AWS Console. Credentials are automatically injected from your active console login as short-lived session tokens — no access keys, no credential files, no bootstrap user required. This eliminates the entire IAM user and Secrets Manager setup from Options A and B.

> **IAM requirement:** The AWS user or role you log into the console with must have permissions to manage S3, CloudFront, and IAM bucket policies. If you are using a root account or an existing admin account this is already satisfied. For least-privilege setups, attach `AmazonS3FullAccess` and `CloudFrontFullAccess` to your console user as described in Step 1 of Option B.

#### Step 1 — Open CloudShell

1. Sign in to the [AWS Console](https://console.aws.amazon.com).
2. Confirm the region in the top-right corner is set to **Canada (Central) — ca-central-1**.
3. Click the **CloudShell** icon in the top navigation bar (the `>_` terminal icon), or type **CloudShell** into the services search bar.
4. Wait ~30 seconds for the environment to initialise on first launch.

#### Step 2 — Install Terraform (one-time)

Terraform is not pre-installed in CloudShell. The script below calls the **HashiCorp Checkpoint API** to automatically resolve the latest stable version, then downloads and installs the binary to `~/bin`. Because CloudShell's home directory persists across sessions, this only needs to be run once.

```bash
# Query the HashiCorp Checkpoint API for the latest stable Terraform version
TERRAFORM_VERSION=$(curl -s https://checkpoint-api.hashicorp.com/v1/check/terraform \
  | jq -r '.current_version')

echo "Installing Terraform v${TERRAFORM_VERSION}..."

# Download and install to ~/bin (persists across CloudShell sessions)
mkdir -p ~/bin
curl -Lo /tmp/terraform.zip \
  "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
unzip -o /tmp/terraform.zip -d ~/bin
rm /tmp/terraform.zip

# Add ~/bin to PATH permanently (skips if already present)
grep -qxF 'export PATH="$HOME/bin:$PATH"' ~/.bashrc \
  || echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

# Confirm the installed version
terraform version
```

#### Step 3 — Get the Terraform files into CloudShell

**Via Git (recommended if your repo is in source control)**

```bash
git clone https://your-repo-url.git
cd your-repo/terraform/jwks_hosting
```

**Via manual upload**

1. Click **Actions** in the top-right corner of the CloudShell panel.
2. Select **Upload file**.
3. Upload `jwks_hosting.tf` and each `jwks.json` file. Re-create the folder structure (e.g. `mkdir -p rpsim`) before uploading files into subdirectories.

#### Step 4 — Run Terraform

No credential configuration is needed. CloudShell is already authenticated as your console user.

```bash
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

For quick exploratory runs, you can omit the `-out` flag and run `terraform plan` then `terraform apply` separately (you'll be prompted to type `yes`):

```bash
terraform init
terraform plan
terraform apply
```

Type `yes` when prompted to confirm (only needed without `-out`).

> **Best practice:** Use `terraform plan -out=tfplan` so the exact reviewed plan is applied without re-evaluation. This is especially important if your session times out — you can safely re-open CloudShell and run `terraform apply tfplan` again with the same plan.

> **Session timeout note:** CloudShell disconnects after **20 minutes of inactivity**. If your session drops during a long `apply` (CloudFront deployments take 5–15 minutes), re-open CloudShell — your home directory and installed Terraform binary will still be there. Run `source ~/.bashrc` to restore your PATH, then check `terraform output` to see what was created.

---

## Project Structure

```
jwks_hosting/
├── jwks_hosting.tf       # Main Terraform configuration
├── README.md             # This file
└── rpsim/
    └── jwks.json         # JWKS file for the "rpsim" application
```

### Adding More Applications

To host JWKS for additional applications, add entries to the `apps_and_jwks` variable in `jwks_hosting.tf` and place the corresponding JSON file in the directory:

```hcl
variable "apps_and_jwks" {
  type = map(string)
  default = {
    "rpsim"     = "rpsim/jwks.json"
    "app-two"   = "app-two/jwks.json"
    "marketing" = "marketing/jwks.json"
  }
}
```

---

## Running the Terraform Script (Local)

If you are using **Option C (CloudShell)**, skip this section — the run steps are included in Option C above.

### 1. Navigate to the module directory

**Mac / Linux**
```bash
cd terraform/jwks_hosting
```

**Windows (PowerShell)**
```powershell
cd terraform\jwks_hosting
```

### 2. Initialise Terraform

Downloads the required AWS provider plugin.

```bash
terraform init
```

### 3. Preview the execution plan

Shows what resources will be created without making any changes. Optionally save the plan to a file so `apply` uses the exact same plan:

```bash
# Quick preview (re-evaluated during apply)
terraform plan

# OR — recommended for production: save the plan to a file
terraform plan -out=tfplan
```

### 4. Apply the configuration

Creates all AWS resources (S3 bucket, CloudFront distribution, bucket policy, etc.).

**If you saved a plan file in step 3:**
```bash
terraform apply tfplan
```

**If you ran plan without `-out`:**
```bash
terraform apply
```

Type `yes` when prompted to confirm (not needed if using a saved plan file).

> **Best practice:** Use `terraform plan -out=tfplan` in production and CI/CD environments. This ensures the exact reviewed plan is applied without re-evaluation or accidental changes.

> **Note:** CloudFront distributions can take **5–15 minutes** to fully deploy after `apply` completes.

### 5. Retrieve the live URLs

After a successful apply, Terraform prints the output:

```
Outputs:

all_jwks_urls = {
  "rpsim" = "https://<cloudfront-domain>/rpsim/.well-known/jwks"
}
```

You can also retrieve this output at any time with:

```bash
terraform output all_jwks_urls
```

---

## Destroying the Infrastructure

To tear down all provisioned resources:

```bash
terraform destroy
```

Type `yes` when prompted. The S3 bucket has `force_destroy = true` set, so all objects will be deleted automatically.

---

## Version Control Setup

### .gitignore

A `.gitignore` file is included in this directory. It excludes:
- The `rpsim/` folder and all `*.json` files (to prevent committing JWKS key material)
- Terraform state files (`*.tfstate`, `*.tfstate.*`)
- Terraform lock files and plugin cache (`.terraform/`, `.terraform.lock.hcl`)
- Editor and OS files (`.DS_Store`, `.vscode/`, `.idea/`, etc.)

### Initialise a Git repository and link to a remote

If this folder is not already part of a Git repository, run these commands to set it up and link it to a remote (e.g. GitHub, GitLab, Bitbucket):

```bash
# Navigate to the AWS repository root
cd /Users/andrew.smith/repos/AWS

# Initialise a local Git repository
git init

# Add all files (the .gitignore will automatically exclude jwks files and state)
git add .

# Create an initial commit
git commit -m "Initial AWS Terraform infrastructure configuration"

# Add the remote repository
# Replace <your-username> with your GitHub/GitLab/Bitbucket username
git remote add origin <remote-url>

# Push to the remote (adjust branch name if not 'main')
git branch -M main
git push -u origin main
```

**Example repository URLs for an "aws" repo:**
- GitHub HTTPS: `https://github.com/your-username/aws.git`
- GitHub SSH: `git@github.com:your-username/aws.git`
- GitLab HTTPS: `https://gitlab.com/your-username/aws.git`
- GitLab SSH: `git@gitlab.com:your-username/aws.git`
- Bitbucket HTTPS: `https://bitbucket.org/your-username/aws.git`
- Bitbucket SSH: `git@bitbucket.org:your-username/aws.git`

### Credentials for Git repositories

If using HTTPS URLs, you may be prompted for credentials. Use:
- **GitHub:** Personal access token (PAT) as the password. [Create a PAT here](https://github.com/settings/tokens).
- **GitLab:** Personal access token or password. [Create a PAT here](https://gitlab.com/-/profile/personal_access_tokens).
- **Bitbucket:** App password (not your main password). [Create an app password here](https://bitbucket.org/account/settings/app-passwords/new/).

Alternatively, use SSH keys to avoid entering credentials on every push:

```bash
# Test SSH connection (e.g. for GitHub)
ssh -T git@github.com

# If prompted, type 'yes' to add GitHub's key to known_hosts
```

---

## Notes

- The S3 bucket has **all public access blocked**. Files are only accessible through CloudFront via Origin Access Control (OAC).
- CloudFront is configured with the **CachingDisabled** managed policy (`4135ea2d-...`) so JWKS updates in S3 are reflected immediately without requiring a cache invalidation.
- All traffic is **HTTPS only** — HTTP requests are automatically redirected.
- The CloudFront distribution has **no geo-restrictions** and is globally accessible.
