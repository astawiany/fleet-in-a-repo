#!/usr/bin/env bats
# Static checks of README, architecture doc and ADRs. Nothing here talks to a cluster.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  ADRS="0001-flux-vs-argocd 0002-monorepo-env-dirs 0003-feature-flags-as-helm-values 0004-github-actions-vs-gitlab-ci 0005-capd-as-local-provider"
}

@test "five ADR files exist with Context, Decision, Consequences and Alternatives headings" {
  for a in $ADRS; do
    f="$ROOT/docs/adr/$a.md"
    [[ -f "$f" ]] || { echo "missing $f"; false; }
    for h in Context Decision Consequences Alternatives; do
      grep -qE "^## $h" "$f" || { echo "$f lacks '## $h'"; false; }
    done
  done
}

@test "README links every ADR" {
  for a in $ADRS; do
    grep -qF "docs/adr/$a.md" "$ROOT/README.md" || { echo "README does not link $a"; false; }
  done
}

@test "README contains the quickstart commands make up, make smoke, make down" {
  for c in "make up" "make smoke" "make down"; do
    grep -qF "$c" "$ROOT/README.md" || { echo "README lacks '$c'"; false; }
  done
}

@test "README and architecture.md each contain a Mermaid diagram" {
  for f in README.md docs/architecture.md; do
    grep -qE '^```mermaid' "$ROOT/$f" || { echo "$f has no mermaid block"; false; }
  done
}

@test "every relative markdown link in README and docs resolves to an existing file" {
  cd "$ROOT"
  files="README.md $(find docs -name '*.md' -not -path 'docs/superpowers/*')"
  n=0
  for f in $files; do
    dir="$(dirname "$f")"
    for link in $(grep -oE '\]\([^)#]+(#[^)]*)?\)' "$f" | sed -E 's/^\]\(//; s/\)$//; s/#.*//'); do
      case "$link" in http*|mailto:*) continue ;; esac
      n=$((n + 1))
      [[ -e "$dir/$link" ]] || { echo "$f: broken link $link"; false; }
    done
  done
  [[ "$n" -gt 5 ]] || { echo "only $n links checked"; false; }
}

@test "repo contains no occurrence of employer names" {
  cd "$ROOT"
  # This file is excluded (its title names the words) and the pattern is assembled from pieces; docs/superpowers and
  # .superpowers (spec, plan, reports) legitimately name the employer as a constraint.
  pat="t""-mobile|te""lekom"
  run grep -rIiE "$pat" . --exclude-dir=.git --exclude-dir=.work --exclude-dir=superpowers --exclude-dir=.superpowers --exclude=docs.bats
  [[ "$status" -eq 1 ]] || { echo "$output"; false; }
}

@test "README keeps the recorded-demo placeholder until the link is added" {
  grep -q "Recorded demo:" "$ROOT/README.md" || { echo "README lacks the 'Recorded demo:' line"; false; }
}
