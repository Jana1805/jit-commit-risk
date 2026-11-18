# Deploy the API on AWS (EC2, CPU)

Runs the API from the repo's `Dockerfile` on one `t3.micro` server, behind
HTTPS (Caddy + a free `<ip>.sslip.io` hostname). Everything is built on AWS:
nothing needs to be installed on your own computer.

Cost: about $12/month (instance ~$7.6, public IP ~$3.6, 10 GB disk ~$0.8).

## Deploy

1. Sign in to the AWS console, pick a region (e.g. N. Virginia `us-east-1`),
   and open **CloudShell** (the `>_` icon in the top bar).
2. Run:

   ```bash
   git clone https://github.com/Jana1805/jit-commit-risk.git
   cd jit-commit-risk
   bash deploy/aws/launch.sh
   ```

3. Enter an email for the budget alert when asked (or press Enter to skip).
4. When it finishes it prints the API URL and API key. Put them in VS Code
   settings as `jitRisk.apiUrl` and `jitRisk.apiKey`.

## Check it

```bash
curl https://<ip>.sslip.io/health
curl -X POST https://<ip>.sslip.io/predict \
  -H 'Content-Type: application/json' -H 'X-API-Key: <key>' \
  -d '{"la":120,"ld":30,"nf":4,"nd":2,"ns":1,"ent":1.2,"ndev":3,"age":10.5,"nuc":5,"aexp":200,"arexp":50,"asexp":80}'
```

## Update after pushing to main

```bash
cd jit-commit-risk && git pull && bash deploy/aws/redeploy.sh
```

## Debug

Console → EC2 → the `jit-commit-risk` instance → **Connect** → **Session Manager**, then:

```bash
sudo tail -50 /var/log/jit-setup.log   # first-boot log
sudo docker logs api                   # API logs
sudo docker logs caddy                 # HTTPS certificate / proxy logs
```

## Remove everything

```bash
bash deploy/aws/teardown.sh
```
