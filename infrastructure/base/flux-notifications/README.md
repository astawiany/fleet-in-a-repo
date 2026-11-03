# Flux commit-status notifications (opt-in)

A `Provider` (type `github`) and an `Alert` that report Flux Kustomization results as GitHub commit
statuses. This directory is NOT part of the default infrastructure (`make up` and the overlays do
not reference it), because the Provider needs a token Secret that the offline default does not have.
Without that Secret the Provider would be NotReady.

APIs: `notification.toolkit.fluxcd.io/v1beta3`, the newest version served by Flux 2.2.3.

## Enable

1. Edit `provider.yaml`: set `spec.address` to your repository URL.
2. Create a GitHub token that may write commit statuses (a fine-grained token with
   "Commit statuses: read and write", or a GitHub App token) and store it as a Secret in
   `flux-system`; the Secret is never committed:

   ```sh
   kubectl -n flux-system create secret generic github-status-token --from-literal=token="$GITHUB_STATUS_TOKEN"
   ```

3. Apply it to a cluster: `kustomize build infrastructure/base/flux-notifications | kubectl apply -f -`,
   or reference this directory from a cluster's own Flux Kustomization.
