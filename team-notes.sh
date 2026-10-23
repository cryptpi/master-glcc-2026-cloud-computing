#!/usr/bin/env bash
#
# team-notes.sh v2.1 - deploy "Team Notes", a tiny multi-user SaaS, on AWS.
#
# Runs from your own terminal (Linux, macOS, or Windows with WSL) - AWS
# CloudShell is NOT needed. If the AWS CLI is missing, the script installs the
# official AWS CLI v2 for you (on Linux into ~/.local, no admin rights needed)
# and then uses it for every step. It checks who you are signed in as, explains
# every step, shows CloudFormation progress live, and tests the finished app.
#
# Needs: Python 3, curl (or wget) and, on Linux, unzip. (CloudShell still works.)
#
#   ./team-notes.sh deploy  [name]   build + deploy (or update) the app
#   ./team-notes.sh status  [name]   show account, stack status, resources, URL
#   ./team-notes.sh login            open your browser to sign in and choose the AWS account
#   ./team-notes.sh whoami           only check which AWS account you are signed in to
#   ./team-notes.sh url     [name]   print only the app URL
#   ./team-notes.sh logs    [name]   tail the Lambda logs live (Ctrl+C to stop)
#   ./team-notes.sh destroy [name]   delete EVERYTHING this script created
#   ./team-notes.sh scaffold         only write the project files (no AWS calls)
#   ./team-notes.sh install-cli      only install the AWS CLI v2 (if it is missing)
#
# Options: -g/--guided (pause before every step)   -y/--yes (no questions)
#          --profile NAME   --region REGION   --no-color
#          --no-install (never install the AWS CLI automatically)
#          --remote (browser sign-in with a link + code; chosen automatically in WSL, VMs,
#                    containers and SSH, where the browser cannot call back to this terminal)
#          --local  (force the automatic same-computer browser sign-in)
#
# [name] defaults to "team-notes". Students sharing ONE AWS account must each use
# their own name, e.g.  ./team-notes.sh deploy team-notes-sara
# (lowercase letters, digits, hyphens; starts with a letter; max 20 chars)
#
# Project files are written to ./team-notes-app/ only if they do not exist, so
# students can edit app.py / index.html and run "deploy" again to update.

set -euo pipefail

VERSION="2.1"
PROJECT_DIR="team-notes-app"
SCRIPT_START=$SECONDS

# ==========================================================================
# 1. Arguments
# ==========================================================================
CMD=""; NAME=""; YES="${YES:-0}"; GUIDED="${GUIDED:-0}"; PROFILE_ARG=""; REGION_ARG=""
NO_INSTALL="${NO_INSTALL:-0}"; REMOTE="${REMOTE:-0}"; LOCAL_LOGIN="${LOCAL_LOGIN:-0}"
REMOTE_REASON=""
LOGIN_PROFILE="team-notes-login"   # profile used for browser sign-in (never touches your other profiles)
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)    YES=1 ;;
    -g|--guided) GUIDED=1 ;;
    --profile)   PROFILE_ARG="${2:-}"; shift || true ;;
    --region)    REGION_ARG="${2:-}"; shift || true ;;
    --no-color)  NO_COLOR=1 ;;
    --no-install) NO_INSTALL=1 ;;
    --remote)    REMOTE=1 ;;
    --local)     LOCAL_LOGIN=1 ;;
    -h|--help)   CMD="help" ;;
    -*)          echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
    *)           if [ -z "$CMD" ]; then CMD="$1"; elif [ -z "$NAME" ]; then NAME="$1"; fi ;;
  esac
  shift || true
done
CMD="${CMD:-help}"
NAME="${NAME:-team-notes}"
STACK="$NAME"
if [ -n "$PROFILE_ARG" ]; then export AWS_PROFILE="$PROFILE_ARG"; fi

# The AWS CLI installer puts "aws" in ~/.local/bin. Make sure we can find it
# (appended, so an "aws" that is already installed system-wide still wins).
LOCAL_BIN_ADDED=0
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) PATH="$PATH:$HOME/.local/bin"; LOCAL_BIN_ADDED=1 ;;
esac

# ==========================================================================
# 2. Look & feel (colors, icons, spinner)
# ==========================================================================
IS_TTY=0; IS_TTY_IN=0
if [ -t 1 ]; then IS_TTY=1; fi
if [ -t 0 ]; then IS_TTY_IN=1; fi

if [ "$GUIDED" = 1 ] && [ "$IS_TTY_IN" != 1 ]; then GUIDED=0; fi

USE_COLOR=0
if [ -z "${NO_COLOR:-}" ]; then
  if { [ "$IS_TTY" = 1 ] && [ "${TERM:-dumb}" != "dumb" ]; } || [ -n "${FORCE_COLOR:-}" ]; then
    USE_COLOR=1
  fi
fi

if [ "$USE_COLOR" = 1 ]; then
  RST=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
  RED=$'\033[91m'; GREEN=$'\033[92m'; YELLOW=$'\033[93m'; BLUE=$'\033[94m'
  MAGENTA=$'\033[95m'; CYAN=$'\033[96m'; GRAY=$'\033[90m'
else
  RST=""; BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""; GRAY=""
fi

case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8*|*utf8*|*UTF8*|*utf-8*)
    OKI="✔"; ERRI="✘"; WARNI="⚠"; PROGI="⟳"; ARR="→"; DOT="•"
    BOX_TL="╭"; BOX_TR="╮"; BOX_BL="╰"; BOX_BR="╯"; BOX_H="─"; BOX_V="│"
    SPIN=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏') ;;
  *)
    OKI="OK"; ERRI="X"; WARNI="!"; PROGI="~"; ARR="->"; DOT="*"
    BOX_TL="+"; BOX_TR="+"; BOX_BL="+"; BOX_BR="+"; BOX_H="-"; BOX_V="|"
    SPIN=('|' '/' '-' '\') ;;
esac

SPIN_I=0
STEP_NO=0
STEP_TOTAL=0
IN_CFN_WAIT=0

clear_line() { if [ "$IS_TTY" = 1 ]; then printf '\r\033[K'; fi; }

spinner_line() { # spinner_line <message> <seconds>
  if [ "$IS_TTY" != 1 ]; then return 0; fi
  SPIN_I=$(( (SPIN_I + 1) % ${#SPIN[@]} ))
  printf '\r\033[K      %s%s%s %s %s%ss%s' "$CYAN" "${SPIN[$SPIN_I]}" "$RST" "$1" "$GRAY" "$2" "$RST"
}

hr() { local s="" i; for ((i = 0; i < 50; i++)); do s+="$BOX_H"; done; printf '%s' "$s"; }

box_line() { # pad by characters (printf %-Ns pads by bytes and breaks on UTF-8 symbols)
  local t="$1" pad
  pad=$((48 - ${#t}))
  if [ "$pad" -lt 0 ]; then pad=0; fi
  printf '  %s%s%s %s%s%*s%s %s%s%s\n' "$CYAN" "$BOX_V" "$RST" "$BOLD" "$t" "$pad" "" "$RST" "$CYAN" "$BOX_V" "$RST"
}

banner() {
  echo
  printf '  %s%s%s%s\n' "$CYAN" "$BOX_TL" "$(hr)" "$BOX_TR$RST"
  box_line "Team Notes - a tiny SaaS on AWS   (v$VERSION)"
  box_line "Cognito + API Gateway + Lambda + DynamoDB"
  printf '  %s%s%s%s\n' "$CYAN" "$BOX_BL" "$(hr)" "$BOX_BR$RST"
}

# The steps of each command (single source of truth: used by help, roadmap and step headers)
DEPLOY_STEPS=("Setting up the AWS CLI and tools" "Signing in to AWS" "Preparing the project files"
              "Packaging and uploading the code" "Building the infrastructure (live)"
              "Checking that the app really works")
DESTROY_STEPS=("Setting up the AWS CLI and tools" "Signing in to AWS" "Reviewing what will be deleted"
               "Deleting the stack (live)" "Removing the code bucket" "Confirming nothing is left")

STEP_TITLES=()
STEP_DUR=()
STEP_T0=$SECONDS

roadmap() { # roadmap "title 1" "title 2" ...   (prints the plan, sets the step list)
  STEP_TITLES=("$@")
  STEP_TOTAL=$#
  local i=1 t
  echo
  printf '  %sWhat will happen, step by step%s\n' "$BOLD" "$RST"
  for t in "$@"; do
    printf '    %s%d.%s %s\n' "$MAGENTA" "$i" "$RST" "$t"
    i=$((i + 1))
  done
  if [ "$GUIDED" = 1 ]; then
    echo
    printf '  %sGuided mode:%s I will pause before every step. Press Enter to run it, or q to stop.\n' "$BOLD$CYAN" "$RST"
  fi
}

pause_step() {
  if [ "$GUIDED" != 1 ]; then return 0; fi
  local ans
  read -r -p "      ${BOLD}Press Enter to run this step${RST} ${GRAY}(q = stop here)${RST} " ans
  case "$ans" in q|Q) die "Stopped by you. Nothing further was changed." ;; esac
}

step() { # step [what-and-why]   (the title comes from the roadmap)
  if [ "$STEP_NO" -ge 1 ]; then STEP_DUR[$((STEP_NO - 1))]=$((SECONDS - STEP_T0)); fi
  STEP_NO=$((STEP_NO + 1))
  local title="${STEP_TITLES[$((STEP_NO - 1))]:-Step $STEP_NO}"
  echo
  printf '%s%s[%d/%d]%s %s%s%s\n' "$BOLD" "$MAGENTA" "$STEP_NO" "$STEP_TOTAL" "$RST" "$BOLD" "$title" "$RST"
  if [ -n "${1:-}" ]; then info "$1"; fi
  pause_step
  STEP_T0=$SECONDS
}

recap() { # list every step with how long it took
  STEP_DUR[$((STEP_NO - 1))]=$((SECONDS - STEP_T0))
  local i
  echo
  printf '  %sRecap%s\n' "$BOLD" "$RST"
  for ((i = 0; i < ${#STEP_TITLES[@]}; i++)); do
    printf '    %s%s%s %d. %-40s %s%ss%s\n' "$GREEN" "$OKI" "$RST" "$((i + 1))" "${STEP_TITLES[$i]}" "$GRAY" "${STEP_DUR[$i]:-0}" "$RST"
  done
}

show_cmd() { # show the real AWS command being run, so students learn it
  printf '      %s$ %s%s\n' "$GRAY" "$*" "$RST"
}

info() { printf '      %s%s%s\n' "$DIM" "$*" "$RST"; }
good() { printf '      %s%s%s %s\n' "$GREEN" "$OKI" "$RST" "$*"; }
warn() { printf '      %s%s%s %s\n' "$YELLOW" "$WARNI" "$RST" "$*"; }
bad()  { printf '      %s%s%s %s\n' "$RED" "$ERRI" "$RST" "$*" >&2; }
kv()   { printf '      %s%-16s%s %s\n' "$GRAY" "$1" "$RST" "$2"; }

die() {
  clear_line
  printf '\n%s%s ERROR%s %s\n' "$RED" "$ERRI" "$RST" "$*" >&2
  exit 1
}

# run "message" command args...   -> live spinner, output shown only on failure
run() {
  local msg="$1"; shift
  local out rc=0 pid t0=$SECONDS
  out="$(mktemp)"
  if [ "$IS_TTY" = 1 ]; then
    "$@" >"$out" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
      spinner_line "$msg" $((SECONDS - t0))
      sleep 0.1
    done
    wait "$pid" || rc=$?
    clear_line
  else
    "$@" >"$out" 2>&1 || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    good "$msg ${GRAY}($((SECONDS - t0))s)${RST}"
    rm -f "$out"
  else
    bad "$msg"
    sed 's/^/          /' "$out" >&2
    rm -f "$out"
    exit "$rc"
  fi
}

on_interrupt() {
  clear_line
  printf '\n%s%s Interrupted.%s\n' "$YELLOW" "$WARNI" "$RST"
  if [ "$IN_CFN_WAIT" = 1 ]; then
    info "If CloudFormation had already started, it keeps working in the cloud."
    info "Check on it with:  $0 status $NAME"
  fi
  local p
  for p in $(jobs -p); do kill "$p" 2>/dev/null || true; done
  exit 130
}
trap on_interrupt INT TERM

usage() {
  banner
  local i=1 t
  cat <<EOF

${BOLD}HOW TO USE IT${RST} ${GRAY}(first time, from your own computer)${RST}
  ${MAGENTA}1.${RST} Open a terminal (Linux, macOS, or Windows with WSL)
  ${MAGENTA}2.${RST} ${BOLD}chmod +x team-notes.sh${RST}
  ${MAGENTA}3.${RST} ${BOLD}./team-notes.sh install-cli${RST}       install the AWS CLI ${GRAY}(optional: deploy installs it if missing)${RST}
  ${MAGENTA}4.${RST} ${BOLD}./team-notes.sh login${RST}            open your browser, sign in and choose the AWS account
  ${MAGENTA}5.${RST} ${BOLD}./team-notes.sh deploy --guided${RST}  build the app, pausing at every step
        ${GRAY}(leave out --guided to run all steps without pausing)${RST}
  ${MAGENTA}6.${RST} Open the URL it prints, sign up with any email, add a note
  ${MAGENTA}7.${RST} ${BOLD}./team-notes.sh destroy${RST}          delete everything when you are done

${BOLD}THE STEPS OF "deploy"${RST}
EOF
  for t in "${DEPLOY_STEPS[@]}"; do
    printf '  %s%d.%s %s\n' "$MAGENTA" "$i" "$RST" "$t"
    i=$((i + 1))
  done
  cat <<EOF

${BOLD}COMMANDS${RST}
  ${GREEN}deploy${RST}   [name]   build + deploy (or update) the app, with live progress
  ${GREEN}status${RST}   [name]   show account, stack status, resources and URL
  ${GREEN}login${RST}              open your browser to sign in and choose the AWS account ${GRAY}(run again to switch)${RST}
  ${GREEN}whoami${RST}             check which AWS account you are signed in to
  ${GREEN}url${RST}      [name]   print only the app URL
  ${GREEN}logs${RST}     [name]   tail the Lambda logs live (Ctrl+C to stop)
  ${GREEN}destroy${RST}  [name]   delete everything this script created
  ${GREEN}scaffold${RST}           only write the project files (no AWS calls)
  ${GREEN}install-cli${RST}        install the AWS CLI v2 if it is missing

${BOLD}OPTIONS${RST}
  -g, --guided       pause before every step (best for demos and learning)
  -y, --yes          do not ask questions
  --profile NAME     use this AWS CLI profile
  --region REGION    use this AWS region
  --no-color         plain output
  --no-install       never install the AWS CLI automatically
  --remote           browser sign-in with a link + code (automatic in WSL, VMs, containers, SSH)
  --local            force the automatic same-computer browser sign-in

${BOLD}SHARING ONE ACCOUNT${RST}
  Each student needs a different [name], e.g.  ./team-notes.sh deploy team-notes-sara
  (lowercase letters, digits, hyphens; starts with a letter; max 20 characters)

EOF
}

write_if_missing() { # write_if_missing <path>   (content comes from stdin)
  if [ -f "$1" ]; then
    cat >/dev/null
    info "kept   $1  (already exists - your edits are safe)"
  else
    cat >"$1"
    good "wrote  $1 ${GRAY}($(wc -l <"$1" | tr -d ' ') lines)${RST}"
  fi
}

# ==========================================================================
# 3. Project files (written only if missing)
# ==========================================================================
scaffold() {
  mkdir -p "$PROJECT_DIR/lambda"

  # ---------------------------- Lambda backend ----------------------------
  write_if_missing "$PROJECT_DIR/lambda/app.py" <<'PYEOF'
import base64
import json
import os
import time
import uuid

import boto3
from boto3.dynamodb.conditions import Key

table = boto3.resource("dynamodb").Table(os.environ["TABLE"])
HERE = os.path.dirname(__file__)


def reply(status, body="", content_type="application/json"):
    if not isinstance(body, str):
        body = json.dumps(body)
    return {"statusCode": status, "headers": {"Content-Type": content_type}, "body": body}


def handler(event, context):
    route = event["routeKey"]

    # Public route: the web page. Cognito settings are injected at runtime.
    if route == "GET /":
        with open(os.path.join(HERE, "index.html"), encoding="utf-8") as f:
            page = f.read()
        page = page.replace("__CLIENT_ID__", os.environ["CLIENT_ID"])
        page = page.replace("__REGION__", os.environ["REGION"])
        return reply(200, page, "text/html; charset=utf-8")

    # Everything below is protected by the Cognito JWT authorizer, so "sub"
    # is the verified id of the logged-in user. This is the multi-tenancy rule:
    # every query below is scoped to that id, so users only see their own data.
    user_id = event["requestContext"]["authorizer"]["jwt"]["claims"]["sub"]
    print(json.dumps({"route": route, "user": user_id}))  # visible in CloudWatch Logs

    if route == "GET /notes":
        items = table.query(KeyConditionExpression=Key("user_id").eq(user_id))["Items"]
        items.sort(key=lambda n: n["created"], reverse=True)
        return reply(200, [{"id": n["note_id"], "text": n["text"], "created": n["created"]} for n in items])

    if route == "POST /notes":
        raw = event.get("body") or "{}"
        if event.get("isBase64Encoded"):
            raw = base64.b64decode(raw).decode("utf-8")
        try:
            text = str(json.loads(raw).get("text", "")).strip()
        except (ValueError, AttributeError):
            return reply(400, {"error": "Invalid JSON"})
        if not text or len(text) > 500:
            return reply(400, {"error": "A note must be 1-500 characters"})
        note = {
            "user_id": user_id,
            "note_id": uuid.uuid4().hex,
            "text": text,
            "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        table.put_item(Item=note)
        return reply(201, {"id": note["note_id"], "text": note["text"], "created": note["created"]})

    if route == "DELETE /notes/{id}":
        table.delete_item(Key={"user_id": user_id, "note_id": event["pathParameters"]["id"]})
        return reply(204)

    return reply(404, {"error": "Not found"})
PYEOF

  # ----------------------------- Web frontend -----------------------------
  write_if_missing "$PROJECT_DIR/lambda/index.html" <<'HTMLEOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Team Notes</title>
<style>
  :root { --bg:#f6f7f9; --card:#fff; --text:#1c1f24; --muted:#6b7280; --accent:#2563eb; --line:#e5e7eb; }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#14171c; --card:#1d2128; --text:#e8eaed; --muted:#9aa3af; --accent:#60a5fa; --line:#2b313a; }
  }
  * { box-sizing: border-box; }
  body { margin:0; font:16px/1.5 system-ui, sans-serif; background:var(--bg); color:var(--text); }
  main { max-width:560px; margin:0 auto; padding:32px 16px; }
  h1 { margin:0 0 16px; font-size:1.6rem; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:16px; margin-bottom:16px; }
  input { width:100%; padding:10px 12px; margin-bottom:8px; border:1px solid var(--line); border-radius:8px;
          background:var(--bg); color:var(--text); font:inherit; }
  button { padding:9px 14px; border:0; border-radius:8px; background:var(--accent); color:#fff; font:inherit; cursor:pointer; }
  button.secondary { background:transparent; color:var(--accent); border:1px solid var(--accent); }
  button.link { background:none; color:var(--muted); padding:0 4px; }
  .row { display:flex; gap:8px; }
  .row input { margin:0; }
  ul { list-style:none; padding:0; margin:0; }
  li { display:flex; justify-content:space-between; gap:12px; padding:10px 0; border-top:1px solid var(--line); }
  li:first-child { border-top:0; }
  small { color:var(--muted); display:block; }
  #msg { color:#dc2626; min-height:1.4em; margin:8px 0 0; }
  [hidden] { display:none !important; }
</style>
</head>
<body>
<main>
  <h1>Team Notes</h1>

  <section id="auth" class="card">
    <input id="email" type="email" placeholder="Email" autocomplete="username">
    <input id="pw" type="password" placeholder="Password (min. 8 characters)" autocomplete="current-password">
    <div class="row">
      <button id="login">Log in</button>
      <button id="signup" class="secondary">Sign up</button>
    </div>
    <p id="msg"></p>
  </section>

  <section id="app" hidden>
    <p>Signed in as <b id="who"></b> <button id="logout" class="link">Log out</button></p>
    <form id="form" class="card row">
      <input id="text" placeholder="Write a note..." maxlength="500" required>
      <button>Add</button>
    </form>
    <div class="card"><ul id="list"></ul></div>
  </section>
</main>

<script>
const CLIENT_ID = "__CLIENT_ID__";
const REGION = "__REGION__";
const $ = (id) => document.getElementById(id);

let token = sessionStorage.getItem("token");
let email = sessionStorage.getItem("email");

async function cognito(target, body) {
  const res = await fetch(`https://cognito-idp.${REGION}.amazonaws.com/`, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-amz-json-1.1",
      "X-Amz-Target": "AWSCognitoIdentityProviderService." + target,
    },
    body: JSON.stringify(body),
  });
  const data = await res.json();
  if (!res.ok) throw new Error(data.message || data.__type || "Request failed");
  return data;
}

async function api(path, options = {}) {
  const res = await fetch(path, {
    ...options,
    headers: { "Content-Type": "application/json", Authorization: "Bearer " + token },
  });
  if (res.status === 401) { logout(); throw new Error("Session expired, please log in again"); }
  if (!res.ok) throw new Error("Request failed (" + res.status + ")");
  return res.status === 204 ? null : res.json();
}

function say(text) { $("msg").textContent = text || ""; }

function show() {
  const loggedIn = Boolean(token);
  $("auth").hidden = loggedIn;
  $("app").hidden = !loggedIn;
  if (loggedIn) { $("who").textContent = email; load(); }
}

function logout() {
  token = null; email = null;
  sessionStorage.clear();
  show();
}

async function login() {
  say("");
  try {
    const em = $("email").value.trim();
    const data = await cognito("InitiateAuth", {
      AuthFlow: "USER_PASSWORD_AUTH",
      ClientId: CLIENT_ID,
      AuthParameters: { USERNAME: em, PASSWORD: $("pw").value },
    });
    token = data.AuthenticationResult.IdToken;
    email = em;
    sessionStorage.setItem("token", token);
    sessionStorage.setItem("email", email);
    show();
  } catch (e) { say(e.message); }
}

async function signup() {
  say("");
  try {
    await cognito("SignUp", { ClientId: CLIENT_ID, Username: $("email").value.trim(), Password: $("pw").value });
    await login();
  } catch (e) { say(e.message); }
}

async function load() {
  const list = $("list");
  list.replaceChildren();
  try {
    const notes = await api("/notes");
    if (!notes.length) {
      const li = document.createElement("li");
      li.textContent = "No notes yet. Add your first one above.";
      list.append(li);
    }
    for (const n of notes) {
      const li = document.createElement("li");
      const box = document.createElement("div");
      box.textContent = n.text;                       // textContent: no HTML injection
      const when = document.createElement("small");
      when.textContent = n.created.replace("T", " ").replace("Z", " UTC");
      box.append(when);
      const del = document.createElement("button");
      del.className = "link";
      del.textContent = "Delete";
      del.onclick = async () => { await api("/notes/" + n.id, { method: "DELETE" }); load(); };
      li.append(box, del);
      list.append(li);
    }
  } catch (e) { /* api() already handled expired sessions */ }
}

$("login").onclick = login;
$("signup").onclick = signup;
$("logout").onclick = logout;
$("form").onsubmit = async (ev) => {
  ev.preventDefault();
  const input = $("text");
  await api("/notes", { method: "POST", body: JSON.stringify({ text: input.value }) });
  input.value = "";
  load();
};

show();
</script>
</body>
</html>
HTMLEOF

  # ------------------------ CloudFormation template -----------------------
  write_if_missing "$PROJECT_DIR/template.yaml" <<'YAMLEOF'
AWSTemplateFormatVersion: '2010-09-09'
Description: Team Notes - a tiny multi-user SaaS (workshop example)

Parameters:
  CodeBucket:
    Type: String
  CodeKey:
    Type: String

Resources:
  # ---- Database: one item per note, partitioned by user ----
  NotesTable:
    Type: AWS::DynamoDB::Table
    Properties:
      BillingMode: PAY_PER_REQUEST
      AttributeDefinitions:
        - AttributeName: user_id
          AttributeType: S
        - AttributeName: note_id
          AttributeType: S
      KeySchema:
        - AttributeName: user_id
          KeyType: HASH
        - AttributeName: note_id
          KeyType: RANGE

  # ---- Authentication: Cognito user pool ----
  # WORKSHOP SHORTCUT: this tiny Lambda auto-confirms every sign-up so students
  # do not need to receive an email. Do NOT do this in a real product.
  AutoConfirmRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal: {Service: lambda.amazonaws.com}
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

  AutoConfirmFunction:
    Type: AWS::Lambda::Function
    Properties:
      Runtime: python3.12
      Handler: index.handler
      Role: !GetAtt AutoConfirmRole.Arn
      Code:
        ZipFile: |
          def handler(event, context):
              event["response"]["autoConfirmUser"] = True
              return event

  UserPool:
    Type: AWS::Cognito::UserPool
    Properties:
      UserPoolName: !Sub '${AWS::StackName}-users'
      UsernameAttributes: [email]
      Policies:
        PasswordPolicy:
          MinimumLength: 8
          RequireLowercase: false
          RequireUppercase: false
          RequireNumbers: false
          RequireSymbols: false
      LambdaConfig:
        PreSignUp: !GetAtt AutoConfirmFunction.Arn

  AutoConfirmPermission:
    Type: AWS::Lambda::Permission
    Properties:
      FunctionName: !Ref AutoConfirmFunction
      Action: lambda:InvokeFunction
      Principal: cognito-idp.amazonaws.com
      SourceArn: !GetAtt UserPool.Arn

  UserPoolClient:
    Type: AWS::Cognito::UserPoolClient
    Properties:
      UserPoolId: !Ref UserPool
      GenerateSecret: false
      ExplicitAuthFlows:
        - ALLOW_USER_PASSWORD_AUTH
        - ALLOW_REFRESH_TOKEN_AUTH

  # ---- Backend: one Lambda serves the page and the API ----
  AppRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal: {Service: lambda.amazonaws.com}
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
      Policies:
        - PolicyName: notes-table-access
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - dynamodb:PutItem
                  - dynamodb:DeleteItem
                  - dynamodb:Query
                Resource: !GetAtt NotesTable.Arn

  AppFunction:
    Type: AWS::Lambda::Function
    Properties:
      Runtime: python3.12
      Handler: app.handler
      Role: !GetAtt AppRole.Arn
      MemorySize: 128
      Timeout: 10
      Code:
        S3Bucket: !Ref CodeBucket
        S3Key: !Ref CodeKey
      Environment:
        Variables:
          TABLE: !Ref NotesTable
          CLIENT_ID: !Ref UserPoolClient
          REGION: !Ref AWS::Region

  # ---- Public entry point: HTTP API with a JWT authorizer ----
  HttpApi:
    Type: AWS::ApiGatewayV2::Api
    Properties:
      Name: !Sub '${AWS::StackName}-api'
      ProtocolType: HTTP

  Integration:
    Type: AWS::ApiGatewayV2::Integration
    Properties:
      ApiId: !Ref HttpApi
      IntegrationType: AWS_PROXY
      IntegrationUri: !GetAtt AppFunction.Arn
      PayloadFormatVersion: '2.0'

  Authorizer:
    Type: AWS::ApiGatewayV2::Authorizer
    Properties:
      ApiId: !Ref HttpApi
      AuthorizerType: JWT
      Name: cognito-jwt
      IdentitySource:
        - '$request.header.Authorization'
      JwtConfiguration:
        Audience:
          - !Ref UserPoolClient
        Issuer: !Sub 'https://cognito-idp.${AWS::Region}.amazonaws.com/${UserPool}'

  RoutePage:
    Type: AWS::ApiGatewayV2::Route
    Properties:
      ApiId: !Ref HttpApi
      RouteKey: 'GET /'
      Target: !Sub 'integrations/${Integration}'

  RouteList:
    Type: AWS::ApiGatewayV2::Route
    Properties:
      ApiId: !Ref HttpApi
      RouteKey: 'GET /notes'
      AuthorizationType: JWT
      AuthorizerId: !Ref Authorizer
      Target: !Sub 'integrations/${Integration}'

  RouteAdd:
    Type: AWS::ApiGatewayV2::Route
    Properties:
      ApiId: !Ref HttpApi
      RouteKey: 'POST /notes'
      AuthorizationType: JWT
      AuthorizerId: !Ref Authorizer
      Target: !Sub 'integrations/${Integration}'

  RouteDelete:
    Type: AWS::ApiGatewayV2::Route
    Properties:
      ApiId: !Ref HttpApi
      RouteKey: 'DELETE /notes/{id}'
      AuthorizationType: JWT
      AuthorizerId: !Ref Authorizer
      Target: !Sub 'integrations/${Integration}'

  Stage:
    Type: AWS::ApiGatewayV2::Stage
    Properties:
      ApiId: !Ref HttpApi
      StageName: '$default'
      AutoDeploy: true

  ApiInvokePermission:
    Type: AWS::Lambda::Permission
    Properties:
      FunctionName: !Ref AppFunction
      Action: lambda:InvokeFunction
      Principal: apigateway.amazonaws.com
      SourceArn: !Sub 'arn:aws:execute-api:${AWS::Region}:${AWS::AccountId}:${HttpApi}/*/*'

Outputs:
  AppUrl:
    Value: !GetAtt HttpApi.ApiEndpoint
  FunctionName:
    Value: !Ref AppFunction
  TableName:
    Value: !Ref NotesTable
  UserPoolId:
    Value: !Ref UserPool
  ClientId:
    Value: !Ref UserPoolClient
YAMLEOF
}

# ==========================================================================
# 4. AWS helpers
# ==========================================================================
STS_ERR=""; ACCOUNT_ID=""; CALLER_ARN=""; CALLER_ID=""; KIND=""
ENV_NAME="local terminal"; REGION=""; BUCKET=""; KEY=""; URL=""
SEEN=""; EVENT_REF=""

stack_status() {
  aws cloudformation describe-stacks --stack-name "$STACK" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true
}

stack_output() { # stack_output <OutputKey>
  aws cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text 2>/dev/null || true
}

validate_name() {
  [[ "$NAME" =~ ^[a-z][a-z0-9-]{1,19}$ ]] ||
    die "Invalid name '$NAME': use lowercase letters, digits and hyphens, start with a letter, max 20 characters."
}

sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }

# --------------------------------------------------------------------------
# Tools (and automatic installation of the AWS CLI)
# --------------------------------------------------------------------------
AWS_CLI_DOCS="https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"

download() { # download <url> <file>
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$2" "$1"
  else
    echo "Neither curl nor wget is installed, so nothing can be downloaded." >&2
    return 1
  fi
}

install_aws_cli_linux() { # official AWS CLI v2 zip, installed for the current user (no sudo)
  local arch url tmp
  case "$(uname -m)" in
    x86_64|amd64)  arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) die "Unsupported CPU type '$(uname -m)'. Install the AWS CLI yourself: $AWS_CLI_DOCS" ;;
  esac
  command -v unzip >/dev/null 2>&1 ||
    die "'unzip' is needed to install the AWS CLI. Install it (Debian/Ubuntu: sudo apt install unzip - Fedora/RHEL: sudo dnf install unzip) and run this script again."
  url="https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip"
  tmp="$(mktemp -d)"
  show_cmd curl "$url" -o awscliv2.zip
  run "Downloading the AWS CLI v2 installer ($arch)" download "$url" "$tmp/awscliv2.zip"
  run "Unpacking the installer" unzip -q "$tmp/awscliv2.zip" -d "$tmp"
  mkdir -p "$HOME/.local/bin"
  show_cmd ./aws/install --install-dir '~/.local/aws-cli' --bin-dir '~/.local/bin'
  run "Installing the AWS CLI into ~/.local (no admin rights needed)" \
    "$tmp/aws/install" --update --install-dir "$HOME/.local/aws-cli" --bin-dir "$HOME/.local/bin"
  rm -rf "$tmp"
}

install_aws_cli_macos() { # official AWS CLI v2 .pkg (macOS asks for your password)
  local url tmp
  url="https://awscli.amazonaws.com/AWSCLIV2.pkg"
  tmp="$(mktemp -d)"
  show_cmd curl "$url" -o AWSCLIV2.pkg
  run "Downloading the AWS CLI v2 installer" download "$url" "$tmp/AWSCLIV2.pkg"
  info "macOS needs administrator rights for this step - you may be asked for your password."
  show_cmd sudo installer -pkg AWSCLIV2.pkg -target /
  sudo installer -pkg "$tmp/AWSCLIV2.pkg" -target / >/dev/null ||
    die "The installer failed. Install the AWS CLI yourself: $AWS_CLI_DOCS"
  rm -rf "$tmp"
  good "Installer finished"
}

ensure_aws_cli() { # installs the AWS CLI when "aws" is not found (or always, with "force")
  if [ "${1:-}" != force ] && command -v aws >/dev/null 2>&1; then return 0; fi
  local ans
  if [ "${1:-}" != force ]; then warn "The AWS CLI is not installed on this computer."; fi
  if [ "$NO_INSTALL" = 1 ]; then
    die "AWS CLI not found and --no-install was given. Install it yourself: $AWS_CLI_DOCS"
  fi
  info "The AWS CLI is the official command-line tool this script uses to build everything."
  if [ "$YES" != 1 ] && [ "$IS_TTY_IN" = 1 ]; then
    read -r -p "      Install the official AWS CLI v2 now? [Y/n] " ans
    case "${ans:-y}" in [Nn]*) die "The AWS CLI is required. Install it ($AWS_CLI_DOCS), then run this script again." ;; esac
  fi
  case "$(uname -s)" in
    Linux)  install_aws_cli_linux ;;
    Darwin) install_aws_cli_macos ;;
    *)      die "Automatic install is not supported on $(uname -s). On Windows, use WSL (Ubuntu) and run this script there, or install the AWS CLI from $AWS_CLI_DOCS" ;;
  esac
  hash -r
  command -v aws >/dev/null 2>&1 ||
    die "The installer finished but 'aws' was not found on your PATH. Open a new terminal and run this script again."
  if [ "$LOCAL_BIN_ADDED" = 1 ] && [ "$(command -v aws)" = "$HOME/.local/bin/aws" ]; then
    warn "To use 'aws' in new terminals too, add this line to ~/.bashrc (or ~/.zshrc):"
    info "      export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi
}

check_aws_cli() {
  ensure_aws_cli
  local v; v="$(aws --version 2>&1 | awk 'NR==1{print $1}')"
  good "AWS CLI        ${GRAY}$v${RST}"
  case "$v" in aws-cli/1.*) warn "AWS CLI v1 detected. v2 is recommended: run '$0 install-cli' after removing v1." ;; esac
}

check_tools() {
  check_aws_cli
  if command -v python3 >/dev/null 2>&1; then
    good "Python 3       ${GRAY}$(python3 --version 2>&1 | awk '{print $2}')${RST}"
  else
    die "python3 not found (needed to zip the Lambda code). Install it, e.g. 'sudo apt install python3' or 'brew install python'."
  fi
  if command -v curl >/dev/null 2>&1; then
    good "curl           ${GRAY}$(curl --version 2>/dev/null | awk 'NR==1{print $2}')${RST}"
  else
    warn "curl not found - the final self-test will be skipped."
  fi
}

# --------------------------------------------------------------------------
# Authentication
# --------------------------------------------------------------------------
resolve_region_quiet() {
  REGION="${REGION_ARG:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"
  if [ -z "$REGION" ]; then REGION="$(aws configure get region 2>/dev/null || true)"; fi
  return 0
}

pick_region() {
  local -a regions=(us-east-1 us-west-2 eu-west-1 eu-west-3 eu-central-1 ap-southeast-1)
  local i=1 r c
  echo
  info "No AWS region is configured. Pick one:"
  for r in "${regions[@]}"; do
    printf '        %s%d)%s %s\n' "$CYAN" "$i" "$RST" "$r"
    i=$((i + 1))
  done
  read -r -p "      Choice [1-${#regions[@]}, or type a region name]: " c
  if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le "${#regions[@]}" ]; then
    REGION="${regions[$((c - 1))]}"
  else
    REGION="$c"
  fi
}

check_identity() {
  local out
  if out="$(aws sts get-caller-identity --region "${REGION:-us-east-1}" \
        --cli-connect-timeout 5 --cli-read-timeout 20 \
        --query '[Account,Arn,UserId]' --output text 2>&1)"; then
    IFS=$'\t' read -r ACCOUNT_ID CALLER_ARN CALLER_ID <<<"$out"
    STS_ERR=""
    return 0
  fi
  STS_ERR="$out"
  return 1
}

classify_auth_error() {
  case "$STS_ERR" in
    *"aws login"*|*"login_session"*)                              echo login ;;
    *"Unable to locate credentials"*|*"NoCredentialProviders"*) echo none ;;
    *"SSO"*|*"sso"*)                                              echo sso ;;
    *"ExpiredToken"*|*"expired"*)                                 echo expired ;;
    *"InvalidClientTokenId"*|*"SignatureDoesNotMatch"*|*"security token"*) echo invalid ;;
    *"Could not connect"*|*"Connect timeout"*|*"Could not resolve"*|*"timed out"*) echo network ;;
    *)                                                            echo other ;;
  esac
}

# --- Browser sign-in (aws login, needs AWS CLI 2.32.0+) ---------------------
aws_supports_login() {
  local v maj min
  v="$(aws --version 2>&1 | awk 'NR==1{print $1}')"; v="${v#aws-cli/}"
  IFS=. read -r maj min _ <<<"$v"
  [[ "$maj" =~ ^[0-9]+$ && "$min" =~ ^[0-9]+$ ]] || return 1
  if [ "$maj" -gt 2 ]; then return 0; fi
  [ "$maj" -eq 2 ] && [ "$min" -ge 32 ]
}

# The default browser sign-in sends the browser back to http://127.0.0.1:<port> on THIS
# machine. That cannot work when the browser lives somewhere else (WSL, VM, container,
# SSH, remote desktop), and the CLI then waits forever. In those places we use the
# "code method" (aws login --remote): open a link anywhere, paste the code back here.
needs_remote_login() { # true when the same-computer browser callback is unlikely to work
  REMOTE_REASON=""
  if [ "$LOCAL_LOGIN" = 1 ]; then return 1; fi
  if [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_TTY:-}" ]; then
    REMOTE_REASON="You are connected over SSH, so the browser cannot reach this terminal."
    return 0
  fi
  if grep -qi microsoft "${PROC_VERSION_FILE:-/proc/version}" 2>/dev/null; then
    REMOTE_REASON="WSL detected: the Windows browser often cannot reach a sign-in callback inside WSL. (Force the automatic way with --local.)"
    return 0
  fi
  if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
    REMOTE_REASON="Container detected: your browser cannot reach this terminal's localhost."
    return 0
  fi
  if [ "$(uname -s)" = Linux ] && [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    REMOTE_REASON="No desktop/browser found on this machine."
    return 0
  fi
  return 1
}

login_profile_exists() {
  local profiles; profiles="$(aws configure list-profiles 2>/dev/null || true)"
  case $'\n'"$profiles"$'\n' in *$'\n'"$LOGIN_PROFILE"$'\n'*) return 0 ;; esac
  return 1
}

login_failed_help() { # login_failed_help <mode>
  warn "The browser sign-in did not finish."
  if [ "${1:-}" != remote ]; then
    info "Nothing happened, or the page loaded but this terminal never heard back? The browser then"
    info "cannot reach this terminal (WSL, a virtual machine, a container, a remote desktop...)."
    info "The code method fixes that: you open a link anywhere and paste a short code here."
  fi
  info "If the browser page said 'Bad Request' / 'outdated link', the usual cause is a missing"
  info "permission, not a bad link. 'aws login' only works for IAM users and roles that have the"
  info "AWS managed policy  SignInLocalDevelopmentAccess  (the root user does not need it):"
  info "  AWS console > IAM > Users > your user > Add permissions > Attach policies directly."
  info "  Cannot do that yourself? Ask your AWS admin. Some organizations block it on purpose."
  info "Or sign in another way: SSO (s) or access keys (a) in the menu - they need no extra policy."
}

browser_login() { # browser_login [remote] [retried]   opens the AWS sign-in page (aws login)
  local mode="${1:-}" retried="${2:-}" prof="$LOGIN_PROFILE" ans watcher="" rc=0
  local -a args=()
  if ! aws_supports_login; then
    warn "Your AWS CLI is too old for browser sign-in ('aws login' needs version 2.32.0 or newer)."
    info "Update it with:  $0 install-cli"
    return 1
  fi
  REMOTE_REASON=""
  if [ "$mode" != remote ]; then
    if [ "$REMOTE" = 1 ]; then mode="remote"; REMOTE_REASON="You asked for the code method (--remote)."
    elif needs_remote_login; then mode="remote"; fi
  fi
  # reuse the current profile only if it already is a browser-login profile
  if [ -n "${AWS_PROFILE:-}" ] && aws configure get login_session >/dev/null 2>&1; then prof="$AWS_PROFILE"; fi
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  args=(login --profile "$prof")
  if [ -n "$REGION" ]; then args+=(--region "$REGION"); fi
  if [ "$mode" = remote ]; then args+=(--remote); fi
  echo
  if [ "$mode" = remote ]; then
    if [ -n "$REMOTE_REASON" ]; then info "$REMOTE_REASON"; fi
    info "Code method - works even when the browser cannot reach this terminal:"
    info "  1. Open the link printed below in any browser (this computer, or your phone)"
    info "  2. Sign in and choose the AWS account / role you want to use"
    info "  3. Copy the code the page shows and paste it here when asked"
  else
    info "Your browser will open the AWS sign-in page. There you can:"
    info "  $DOT sign in, or pick an AWS session you are already signed in to"
    info "  $DOT choose the AWS account / role you want to use"
    info "If no browser opens, copy the link printed below into one."
    info "Nothing happens after a minute? Press Ctrl+C: the script then offers the code method."
  fi
  info "Page says 'Bad Request'? Press Ctrl+C here: the script explains the usual cause."
  show_cmd aws "${args[@]}"
  if [ "$mode" != remote ]; then
    ( # friendly nudge if the browser never calls back
      i=0
      while [ "$i" -lt "${LOGIN_HINT_AFTER:-45}" ]; do sleep 1; i=$((i + 1)); done
      printf '\n      %s%s Still waiting for the browser.%s Finished in the browser but nothing happens here?\n' "$YELLOW" "$WARNI" "$RST" >&2
      printf '      Press Ctrl+C: this terminal probably cannot be reached by the browser. The script\n' >&2
      printf '      then offers the code method (link + code), which works everywhere.\n' >&2
    ) &
    watcher=$!
  fi
  trap ':' INT                     # Ctrl+C stops 'aws login' but not this script
  aws "${args[@]}" || rc=$?
  trap on_interrupt INT TERM
  if [ -n "$watcher" ]; then
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
  fi
  if [ "$rc" -ne 0 ]; then
    echo
    login_failed_help "$mode"
    if [ "$mode" != remote ] && [ "$retried" != retried ] && [ "$IS_TTY_IN" = 1 ]; then
      echo
      read -r -p "      Try the code method (link + code) now? [Y/n] " ans
      case "${ans:-y}" in
        [Nn]*) return 1 ;;
      esac
      browser_login remote retried
      return $?
    fi
    return 1
  fi
  export AWS_PROFILE="$prof"
  good "Browser sign-in finished ${GRAY}(profile $prof)${RST}"
  info "The next run reuses it until the AWS session expires; then you are offered the browser again."
  return 0
}

# Try to help the person sign in. Returns 0 if something was attempted (retry),
# 1 if there is nothing we can do automatically.
offer_login_fix() { # offer_login_fix <kind>
  local kind="$1" ans p i pname
  if [ "$kind" = network ]; then return 1; fi
  if [ "$ENV_NAME" = "AWS CloudShell" ]; then return 1; fi
  if [ "$IS_TTY_IN" != 1 ]; then return 1; fi

  if [ "$kind" = sso ]; then
    read -r -p "      Open the browser login now (aws sso login)? [Y/n] " ans
    case "${ans:-y}" in [Nn]*) return 1 ;; esac
    if [ -n "${AWS_PROFILE:-}" ]; then aws sso login --profile "$AWS_PROFILE" || true; else aws sso login || true; fi
    return 0
  fi

  if [ "$kind" = login ] || { [ "$kind" = expired ] && [ "${AWS_PROFILE:-}" = "$LOGIN_PROFILE" ]; }; then
    read -r -p "      Your AWS browser sign-in is missing or has expired. Open the browser to sign in? [Y/n] " ans
    case "${ans:-y}" in [Nn]*) return 1 ;; esac
    browser_login || true
    return 0
  fi

  local -a plist=()
  while IFS= read -r p; do
    if [ -n "$p" ]; then plist+=("$p"); fi
  done < <(aws configure list-profiles 2>/dev/null || true)

  echo
  info "How would you like to sign in?"
  printf '        %sb)%s sign in with your browser %s(opens a link: you pick the AWS account there)%s\n' "$CYAN" "$RST" "$GRAY" "$RST"
  printf '        %sr)%s browser on another device %s(this machine has no browser)%s\n' "$CYAN" "$RST" "$GRAY" "$RST"
  printf '        %ss)%s SSO / IAM Identity Center %s(runs: aws configure sso)%s\n' "$CYAN" "$RST" "$GRAY" "$RST"
  printf '        %sa)%s enter access keys now %s(runs: aws configure)%s\n' "$CYAN" "$RST" "$GRAY" "$RST"
  i=1
  for p in "${plist[@]+"${plist[@]}"}"; do
    printf '        %s%d)%s use saved profile %s%s%s\n' "$CYAN" "$i" "$RST" "$BOLD" "$p" "$RST"
    i=$((i + 1))
  done
  printf '        %sq)%s quit\n' "$CYAN" "$RST"
  read -r -p "      Choice [b]: " ans
  case "${ans:-b}" in
    q|Q) return 1 ;;
    b|B) browser_login || true
         return 0 ;;
    r|R) browser_login remote || true
         return 0 ;;
    s|S)
      unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE
      aws configure sso || return 1
      read -r -p "      Profile name you just created: " pname
      if [ -z "$pname" ]; then return 1; fi
      export AWS_PROFILE="$pname"
      return 0 ;;
    a|A)
      info "Get an access key in the AWS console: IAM > Users > your user > Security credentials > Create access key."
      unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE
      aws configure
      return 0 ;;
    *[!0-9]*) return 1 ;;
    *)
      if [ "$ans" -ge 1 ] && [ "$ans" -le "${#plist[@]}" ]; then
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
        export AWS_PROFILE="${plist[$((ans - 1))]}"
        good "Using profile $AWS_PROFILE"
        return 0
      fi
      return 1 ;;
  esac
}

auth_help_and_exit() {
  echo
  printf '  %s%s Could not sign in to AWS.%s The AWS CLI needs credentials. Easiest ways:\n\n' "$RED" "$ERRI" "$RST"
  printf '    %s1)%s %s%s login%s   opens your browser: sign in and choose the AWS account\n' "$CYAN" "$RST" "$BOLD" "$0" "$RST"
  printf '       %s(add --remote if this machine has no browser)%s\n' "$GRAY" "$RST"
  printf '       %sBrowser shows "Bad Request"? Your IAM user needs the SignInLocalDevelopmentAccess policy.%s\n' "$GRAY" "$RST"
  printf '    %s2)%s %saws configure sso%s   for SSO / IAM Identity Center (opens your browser)\n' "$CYAN" "$RST" "$BOLD" "$RST"
  printf '    %s3)%s %saws configure%s       with an IAM user access key\n' "$CYAN" "$RST" "$BOLD" "$RST"
  printf '       %sAWS console > IAM > Users > your user > Security credentials > Create access key%s\n\n' "$GRAY" "$RST"
  printf '  %sThe account needs permission to create IAM roles, Lambda, API Gateway, Cognito,%s\n' "$GRAY" "$RST"
  printf '  %sDynamoDB, S3 and CloudFormation stacks (use a sandbox/workshop account).%s\n\n' "$GRAY" "$RST"
  exit 1
}

show_identity() {
  local role src acct_alias
  case "$CALLER_ARN" in
    *:root)             KIND="root";  role="account root user" ;;
    *:user/*)           KIND="user";  role="IAM user  ${BOLD}${CALLER_ARN##*/}${RST}" ;;
    *:assumed-role/*)   KIND="role";  role="${CALLER_ARN#*:assumed-role/}"
                        role="assumed role  ${BOLD}${role%%/*}${RST} ${GRAY}(session ${role#*/})${RST}" ;;
    *)                  KIND="other"; role="$CALLER_ARN" ;;
  esac
  src="$(aws configure list 2>/dev/null | awk '$1=="access_key"{print $3}' || true)"
  if [ -n "${AWS_PROFILE:-}" ] && aws configure get login_session >/dev/null 2>&1; then src="browser sign-in (aws login)"; fi
  case "$src" in
    env)                         src="environment variables" ;;
    shared-credentials-file)     src="credentials file ($HOME/.aws)" ;;
    config-file)                 src="config file" ;;
    sso)                         src="SSO login" ;;
    iam-role|container-role)     src="temporary role credentials" ;;
    assume-role)                 src="assumed role" ;;
    ""|"<not")                   src="(unknown)" ;;
  esac
  acct_alias="$(aws iam list-account-aliases --query 'AccountAliases[0]' --output text 2>/dev/null || true)"
  echo
  good "${BOLD}Signed in to AWS${RST}"
  kv "Account ID"   "${BOLD}${CYAN}${ACCOUNT_ID}${RST}"
  if [ -n "$acct_alias" ] && [ "$acct_alias" != "None" ]; then kv "Account alias" "$acct_alias"; fi
  kv "You are"      "$role"
  kv "ARN"          "${GRAY}${CALLER_ARN}${RST}"
  kv "Credentials"  "$src"
  kv "Region"       "${BOLD}${REGION}${RST}"
  if [ -n "${AWS_PROFILE:-}" ]; then kv "Profile" "$AWS_PROFILE"; fi
  kv "Running in"   "$ENV_NAME"
  if [ "$KIND" = root ]; then
    echo
    warn "${YELLOW}You are using the ROOT user.${RST} AWS advises an IAM user or SSO for everyday work."
  fi
}

authenticate() {
  if [ "${AWS_EXECUTION_ENV:-}" = "CloudShell" ]; then ENV_NAME="AWS CloudShell"; fi
  info "Asking AWS who you are:"
  show_cmd aws sts get-caller-identity
  resolve_region_quiet
  local tries=0 kind
  until check_identity; do
    tries=$((tries + 1))
    kind="$(classify_auth_error)"
    if [ "$kind" = none ] && [ -z "${AWS_PROFILE:-}" ] && login_profile_exists; then
      info "No default credentials; trying your earlier browser sign-in (profile $LOGIN_PROFILE)."
      export AWS_PROFILE="$LOGIN_PROFILE"
      resolve_region_quiet
      continue
    fi
    warn "Not signed in ${GRAY}(${kind})${RST}"
    info "${STS_ERR%%$'\n'*}"
    if [ "$kind" = network ]; then
      die "Cannot reach AWS. Check your internet connection or proxy settings."
    fi
    if [ "$tries" -ge 4 ] || ! offer_login_fix "$kind"; then auth_help_and_exit; fi
    resolve_region_quiet
  done
  if [ -z "$REGION" ]; then
    if [ "$IS_TTY_IN" = 1 ]; then pick_region; fi
  fi
  [ -n "$REGION" ] || die "No AWS region set. Run: export AWS_REGION=eu-west-1  (or use --region)"
  [[ "$REGION" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ ]] || die "'$REGION' does not look like an AWS region name."
  export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
  show_identity
}

init_context() {
  BUCKET="${STACK}-code-${ACCOUNT_ID}-${REGION}"
}

confirm_target() { # confirm_target "<what we are about to do>"
  local ans sw def
  if [ "$YES" = 1 ] || [ "$IS_TTY_IN" != 1 ]; then
    echo
    good "Continuing without asking ${GRAY}(--yes or non-interactive)${RST}"
    return 0
  fi
  while :; do
    echo
    def="y"
    if [ "$KIND" = root ]; then def="n"; fi
    info "Not the right AWS account? Answer n, then pick another one in your browser."
    read -r -p "      ${BOLD}$1${RST} in account ${BOLD}${ACCOUNT_ID}${RST} (${REGION})? [$([ "$def" = y ] && echo 'Y/n' || echo 'y/N')] " ans
    case "${ans:-$def}" in
      [Yy]*) return 0 ;;
    esac
    read -r -p "      Sign in to a different AWS account with your browser now? [Y/n] " sw
    case "${sw:-y}" in [Nn]*) die "Cancelled. Nothing was changed." ;; esac
    browser_login || die "Browser sign-in did not finish. Nothing was changed."
    check_identity || die "Not signed in after the browser login. Nothing was changed."
    show_identity
    init_context
  done
}

# --------------------------------------------------------------------------
# Packaging
# --------------------------------------------------------------------------
create_bucket() {
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET"
  else
    aws s3api create-bucket --bucket "$BUCKET" \
      --create-bucket-configuration "LocationConstraint=$REGION"
  fi
  aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
}

package_zip() {
  mkdir -p "$PROJECT_DIR/build"
  rm -f "$PROJECT_DIR/build/function.zip"
  (cd "$PROJECT_DIR/lambda" && python3 -m zipfile -c ../build/function.zip app.py index.html)
}

package_and_upload() {
  [ -f "$PROJECT_DIR/lambda/app.py" ] || die "Missing $PROJECT_DIR/lambda/app.py"
  KEY="function-$(cat "$PROJECT_DIR/lambda/app.py" "$PROJECT_DIR/lambda/index.html" | sha | cut -c1-12).zip"
  if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    good "Code bucket ready ${GRAY}($BUCKET)${RST}"
  else
    show_cmd aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
    run "Creating private S3 bucket $BUCKET" create_bucket
  fi
  run "Zipping app.py + index.html" package_zip
  kv "Package" "$(wc -c <"$PROJECT_DIR/build/function.zip" | tr -d ' ') bytes ${GRAY}(key: $KEY)${RST}"
  show_cmd aws s3 cp function.zip "s3://$BUCKET/$KEY"
  run "Uploading code to S3" aws s3 cp "$PROJECT_DIR/build/function.zip" "s3://$BUCKET/$KEY" --only-show-errors
}

# --------------------------------------------------------------------------
# Live CloudFormation events
# --------------------------------------------------------------------------
plan_row() { printf '      %s%s%s %-20s %s%s%s\n' "$CYAN" "$DOT" "$RST" "$1" "$GRAY" "$2" "$RST"; }

show_plan() {
  info "This stack will contain:"
  plan_row "Cognito user pool"  "sign-up and login for your users"
  plan_row "DynamoDB table"     "stores the notes, one partition per user"
  plan_row "2 Lambda functions" "the app (page + API) and a sign-up helper"
  plan_row "HTTP API Gateway"   "public HTTPS URL; rejects requests without a valid login"
  plan_row "IAM roles"          "the minimum permissions each Lambda needs"
}

snapshot_events() {
  : >"$SEEN"
  aws cloudformation describe-stack-events --stack-name "$EVENT_REF" \
    --query 'StackEvents[].EventId' --output text 2>/dev/null | tr '\t' '\n' >>"$SEEN" || true
}

format_event() { # format_event <logical> <type> <status> <reason>
  local logical="$1" rtype="${2#AWS::}" status="$3" reason="$4" color icon
  case "$status" in
    *FAILED*|*ROLLBACK*) color="$RED";    icon="$ERRI" ;;
    *COMPLETE*)          color="$GREEN";  icon="$OKI" ;;
    *IN_PROGRESS*)       color="$YELLOW"; icon="$PROGI" ;;
    *)                   color="$GRAY";   icon="$DOT" ;;
  esac
  clear_line
  printf '      %s%s%s  %s%s %-24s%s %-26s %s%s%s\n' "$GRAY" "$(date +%T)" "$RST" \
    "$color" "$icon" "$status" "$RST" "$logical" "$GRAY" "$rtype" "$RST"
  case "$status" in
    *FAILED*) if [ -n "$reason" ] && [ "$reason" != "None" ]; then printf '                 %s%s%s\n' "$RED" "$reason" "$RST"; fi ;;
  esac
}

print_new_events() {
  local id logical rtype status reason
  while IFS=$'\t' read -r id logical rtype status reason; do
    [ -n "$id" ] || continue
    if grep -qxF "$id" "$SEEN" 2>/dev/null; then continue; fi
    echo "$id" >>"$SEEN"
    if [ "$rtype" = "AWS::CloudFormation::Stack" ]; then
      format_event "(whole stack)" "$rtype" "$status" "$reason"
    else
      format_event "$logical" "$rtype" "$status" "$reason"
    fi
  done < <(aws cloudformation describe-stack-events --stack-name "$EVENT_REF" \
      --query 'reverse(StackEvents[].[EventId,LogicalResourceId,ResourceType,ResourceStatus,ResourceStatusReason])' \
      --output text 2>/dev/null || true)
}

watch_events() { # watch_events <pid> <label>
  local pid="$1" label="$2" i=0 t0=$SECONDS
  IN_CFN_WAIT=1
  while kill -0 "$pid" 2>/dev/null; do
    if [ $((i % 8)) -eq 0 ]; then print_new_events; fi
    spinner_line "$label" $((SECONDS - t0))
    sleep 0.25
    i=$((i + 1))
  done
  clear_line
  print_new_events
  IN_CFN_WAIT=0
}

show_failures() {
  echo
  bad "${BOLD}Something went wrong.${RST} Failed resources:"
  aws cloudformation describe-stack-events --stack-name "$EVENT_REF" \
    --query "StackEvents[?contains(ResourceStatus,'FAILED')].[LogicalResourceId,ResourceStatusReason]" \
    --output text 2>/dev/null | head -n 5 | sed 's/^/          /' >&2 || true
}

wait_deleted() {
  local s
  while :; do
    s="$(stack_status)"
    case "$s" in
      ""|DELETE_COMPLETE) return 0 ;;
      DELETE_FAILED)      return 1 ;;
    esac
    sleep 3
  done
}

deploy_stack() {
  local st mode log rc=0 pid
  st="$(stack_status)"
  case "$st" in
    "")
      mode="create"; good "No stack named ${BOLD}$STACK${RST} yet: creating a new one." ;;
    ROLLBACK_COMPLETE|CREATE_FAILED|ROLLBACK_FAILED|DELETE_FAILED)
      warn "A previous attempt left the stack in state ${RED}$st${RST} and blocks a new deploy."
      info "Cleaning it up first (this is safe: it never finished creating)."
      EVENT_REF="$(aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].StackId' --output text)"
      SEEN="$(mktemp)"; snapshot_events
      aws cloudformation delete-stack --stack-name "$STACK"
      wait_deleted & pid=$!
      watch_events "$pid" "Removing the failed stack"
      wait "$pid" || die "Could not delete the failed stack. Delete it in the CloudFormation console, then retry."
      mode="create" ;;
    *_IN_PROGRESS)
      die "Stack '$STACK' is busy ($st). Wait a minute and run again, or check: $0 status $NAME" ;;
    *)
      mode="update"; good "Stack ${BOLD}$STACK${RST} exists ${GRAY}($st)${RST}: updating it." ;;
  esac
  [ "$mode" = create ] && show_plan

  EVENT_REF="$STACK"
  SEEN="$(mktemp)"; snapshot_events
  log="$(mktemp)"
  echo
  info "Live CloudFormation events (yellow = working, green = done, red = problem):"
  show_cmd aws cloudformation deploy --stack-name "$STACK" --template-file template.yaml --capabilities CAPABILITY_IAM
  aws cloudformation deploy \
    --stack-name "$STACK" \
    --template-file "$PROJECT_DIR/template.yaml" \
    --capabilities CAPABILITY_IAM \
    --no-fail-on-empty-changeset \
    --parameter-overrides "CodeBucket=$BUCKET" "CodeKey=$KEY" >"$log" 2>&1 &
  pid=$!
  watch_events "$pid" "Waiting for CloudFormation"
  wait "$pid" || rc=$?
  if [ "$rc" -ne 0 ]; then
    show_failures
    echo; info "Last lines from the AWS CLI:"
    tail -n 8 "$log" | sed 's/^/          /' >&2
    echo
    info "Common causes: missing permissions (iam:CreateRole), a service blocked on the Free plan, or a name already used."
    rm -f "$log" "$SEEN"
    exit 1
  fi
  rm -f "$log" "$SEEN"
  echo
  good "Stack ${BOLD}$STACK${RST} is ${GREEN}$(stack_status)${RST}"
}

# --------------------------------------------------------------------------
# Verification
# --------------------------------------------------------------------------
http_code() { curl -s -o /dev/null -m 10 -w '%{http_code}' "$1" 2>/dev/null || true; }

verify_app() {
  URL="$(stack_output AppUrl)"
  [ -n "$URL" ] || die "Could not read the app URL from the stack outputs."
  kv "URL" "${BOLD}${CYAN}$URL${RST}"
  if ! command -v curl >/dev/null 2>&1; then
    warn "curl not found, skipping the self-test."
    return 0
  fi
  info "A new API can take a few seconds to answer. Testing from here..."
  show_cmd curl "$URL/"
  local t0=$SECONDS code="000" n
  while [ $((SECONDS - t0)) -lt 60 ]; do
    code="$(http_code "$URL/")"
    if [ "$code" = "200" ]; then break; fi
    for n in 1 2 3 4 5 6 7 8; do
      spinner_line "Waiting for the public URL (last answer: HTTP $code)" $((SECONDS - t0))
      sleep 0.25
    done
  done
  clear_line
  if [ "$code" = "200" ]; then
    good "Web page is online: ${GRAY}GET /${RST} ${ARR} HTTP 200"
  else
    warn "The page did not answer 200 yet (HTTP $code). Give it a minute and open the URL."
  fi
  code="$(http_code "$URL/notes")"
  if [ "$code" = "401" ]; then
    good "API is protected: ${GRAY}GET /notes without login${RST} ${ARR} HTTP 401 ${GRAY}(correct!)${RST}"
  else
    warn "Expected HTTP 401 for /notes without a login, got $code."
  fi
}

show_resources() {
  local rtype rid rstat color
  info "Resources in stack $STACK:"
  while IFS=$'\t' read -r rtype rid rstat; do
    [ -n "$rtype" ] || continue
    case "$rstat" in *FAILED*) color="$RED" ;; *COMPLETE*) color="$GREEN" ;; *) color="$YELLOW" ;; esac
    printf '      %s%s%s %-34s %-24s %s%s%s\n' "$color" "$DOT" "$RST" "${rtype#AWS::}" "$rid" "$color" "$rstat" "$RST"
  done < <(aws cloudformation describe-stack-resources --stack-name "$STACK" \
      --query 'StackResources[].[ResourceType,LogicalResourceId,ResourceStatus]' --output text 2>/dev/null || true)
}

summary() {
  local fn tbl
  fn="$(stack_output FunctionName)"; tbl="$(stack_output TableName)"
  recap
  echo
  printf '  %s%s%s\n' "$GREEN" "$(hr)" "$RST"
  printf '  %s%s  Team Notes is live!%s   %s(took %ss)%s\n' "$BOLD$GREEN" "$OKI" "$RST" "$GRAY" "$((SECONDS - SCRIPT_START))" "$RST"
  printf '  %s%s%s\n\n' "$GREEN" "$(hr)" "$RST"
  kv "Open it"   "${BOLD}${CYAN}$URL${RST}"
  kv "Account"   "$ACCOUNT_ID ${GRAY}($REGION)${RST}"
  kv "Stack"     "$STACK"
  echo
  info "Try it: open the URL, sign up with any email + a password (8+ characters), add a note."
  info "Then sign up a second user in a private window: they will not see your notes."
  echo
  printf '  %sUseful links%s\n' "$BOLD" "$RST"
  kv "CloudFormation" "https://${REGION}.console.aws.amazon.com/cloudformation/home?region=${REGION}#/stacks"
  if [ -n "$fn" ]; then kv "Lambda" "https://${REGION}.console.aws.amazon.com/lambda/home?region=${REGION}#/functions/${fn}"; fi
  if [ -n "$tbl" ]; then kv "DynamoDB" "https://${REGION}.console.aws.amazon.com/dynamodbv2/home?region=${REGION}#table?name=${tbl}"; fi
  echo
  printf '  %sNext steps%s\n' "$BOLD" "$RST"
  kv "Edit the code" "$PROJECT_DIR/lambda/app.py or index.html"
  kv "Redeploy"      "$0 deploy $NAME"
  kv "Watch logs"    "$0 logs $NAME"
  kv "Clean up"      "$0 destroy $NAME   ${GRAY}(do this when you are done)${RST}"
  echo
}

# ==========================================================================
# 5. Commands
# ==========================================================================
cmd_deploy() {
  validate_name
  banner
  roadmap "${DEPLOY_STEPS[@]}"
  step "Making sure the AWS CLI, Python and curl are available (the AWS CLI is installed for you if missing)."
  check_tools
  step "We ask AWS who you are, so you know exactly which account will be changed."
  authenticate; init_context
  confirm_target "Deploy '$STACK'"
  step "Writing app.py (backend), index.html (frontend) and template.yaml (infrastructure). Existing files are never overwritten."
  scaffold
  step "Zip the code and put it in a private S3 bucket, because CloudFormation reads it from there."
  package_and_upload
  step "CloudFormation now creates every cloud resource. Watch each one appear below."
  deploy_stack
  step "We call the new URL ourselves to prove the app works and is protected."
  verify_app
  summary
}

cmd_install_cli() {
  YES=1   # the person asked for the install explicitly: no extra question
  banner
  roadmap "Installing the AWS CLI"
  step "Downloads the official AWS CLI v2 from awscli.amazonaws.com. If it is already installed (and new enough), nothing is changed."
  if command -v aws >/dev/null 2>&1 && ! aws_supports_login; then
    info "Your AWS CLI is older than 2.32.0, which browser sign-in needs - installing the latest v2."
    ensure_aws_cli force
    if ! aws_supports_login; then
      warn "'aws' still resolves to an older version ($(command -v aws)). Remove it, or put ~/.local/bin first in PATH."
    fi
  fi
  check_aws_cli
  recap
  echo
  info "Next: sign in with your browser and choose the AWS account:  $0 login"
  echo
}

cmd_status() {
  validate_name
  banner
  roadmap "Setting up the AWS CLI and tools" "Signing in to AWS" "Looking up stack '$STACK'"
  step "Making sure the AWS CLI is available (it is installed for you if missing)."
  check_tools
  step "We ask AWS who you are."
  authenticate; init_context
  step "Reading the stack and its resources from CloudFormation."
  local st; st="$(stack_status)"
  if [ -z "$st" ]; then
    warn "No stack named '$STACK' in this account and region."
    info "Create it with:  $0 deploy $NAME"
    return 0
  fi
  case "$st" in *COMPLETE*) good "Stack status: ${GREEN}$st${RST}" ;; *FAILED*|*ROLLBACK*) bad "Stack status: $st" ;; *) warn "Stack status: $st" ;; esac
  show_resources
  URL="$(stack_output AppUrl)"
  if [ -n "$URL" ]; then kv "URL" "${BOLD}${CYAN}$URL${RST}"; fi
  echo
}

cmd_login() {
  banner
  roadmap "Setting up the AWS CLI" "Signing in with your browser" "Confirming the account"
  step "Making sure the AWS CLI is available (it is installed for you if missing)."
  check_aws_cli
  step "Your browser opens the AWS sign-in page. Sign in, then choose the AWS account you want to use. Run this command again any time to switch accounts."
  resolve_region_quiet
  browser_login || die "Browser sign-in did not finish. Fix the cause above, or sign in another way: $0 whoami (menu: SSO / access keys)."
  step "We ask AWS who you are, to confirm you ended up in the right account."
  authenticate
  echo
  info "Right account? Next: $0 deploy --guided"
  info "Wrong account? Run '$0 login' again and pick a different one."
  echo
}

cmd_whoami() {
  banner
  roadmap "Setting up the AWS CLI" "Signing in to AWS"
  step "Making sure the AWS CLI is available (it is installed for you if missing)."
  check_aws_cli
  step "We ask AWS which account and identity your terminal is using."
  authenticate
  echo
  info "This is the account the other commands will change. Next: $0 deploy --guided"
  info "Wrong account? Run '$0 login' and choose another one in your browser."
  echo
}

cmd_url() {
  validate_name
  if [ "${AWS_EXECUTION_ENV:-}" = "CloudShell" ]; then ENV_NAME="AWS CloudShell"; fi
  resolve_region_quiet
  command -v aws >/dev/null 2>&1 || die "The AWS CLI is not installed. Run: $0 install-cli"
  check_identity || die "Not signed in to AWS. Run '$0 login' to sign in with your browser."
  [ -n "$REGION" ] || die "No AWS region set (use --region)."
  export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
  local u; u="$(stack_output AppUrl)"
  [ -n "$u" ] || die "No stack named '$STACK' found in $REGION."
  echo "$u"
}

cmd_logs() {
  validate_name
  banner
  roadmap "Setting up the AWS CLI and tools" "Signing in to AWS" "Streaming logs live"
  step "Making sure the AWS CLI is available (it is installed for you if missing)."
  check_tools
  step "We ask AWS who you are."
  authenticate; init_context
  step "Every request to the app shows up below. Open the site and add a note. Ctrl+C to stop."
  local fn; fn="$(stack_output FunctionName)"
  [ -n "$fn" ] || die "No stack named '$STACK' found. Deploy first: $0 deploy $NAME"
  show_cmd aws logs tail "/aws/lambda/$fn" --follow
  echo
  aws logs tail "/aws/lambda/$fn" --follow --since 10m --format short
}

cmd_destroy() {
  validate_name
  banner
  roadmap "${DESTROY_STEPS[@]}"
  step "Making sure the AWS CLI, Python and curl are available (the AWS CLI is installed for you if missing)."
  check_tools
  step "We ask AWS who you are, so you know exactly which account will be cleaned."
  authenticate; init_context
  step "Listing what exists, so you can see exactly what will disappear."
  local st rc=0 pid ans; st="$(stack_status)"
  if [ -z "$st" ]; then
    warn "No stack named '$STACK' in this account and region: nothing to delete there."
  else
    show_resources
    echo
    warn "This permanently deletes the app, ${BOLD}all notes and all user accounts${RST}."
    if [ "$YES" != 1 ]; then
      [ "$IS_TTY_IN" = 1 ] || die "Refusing to delete without confirmation. Use --yes."
      read -r -p "      Type 'yes' to delete '$STACK' from account $ACCOUNT_ID: " ans
      [ "$ans" = "yes" ] || die "Cancelled. Nothing was deleted."
    fi
  fi
  step "CloudFormation removes every resource it created. Watch them disappear."
  if [ -z "$st" ]; then
    info "Skipped (no stack)."
  else
    EVENT_REF="$(aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].StackId' --output text)"
    SEEN="$(mktemp)"; snapshot_events
    show_cmd aws cloudformation delete-stack --stack-name "$STACK"
    aws cloudformation delete-stack --stack-name "$STACK"
    wait_deleted & pid=$!
    watch_events "$pid" "Waiting for CloudFormation"
    wait "$pid" || rc=$?
    rm -f "$SEEN"
    if [ "$rc" -ne 0 ]; then show_failures; die "Stack deletion failed. Check the CloudFormation console."; fi
    good "Stack deleted"
  fi
  step "The private S3 bucket that held the code is emptied and deleted."
  if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    run "Emptying bucket $BUCKET" aws s3 rm "s3://$BUCKET" --recursive --only-show-errors
    run "Deleting the bucket" aws s3api delete-bucket --bucket "$BUCKET"
  else
    good "No code bucket left"
  fi
  step "We ask AWS again, to be sure nothing is left that could cost money."
  if [ -z "$(stack_status)" ]; then good "Stack '$STACK' no longer exists"; else warn "Stack still visible - it may take a moment."; fi
  if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then warn "Bucket still exists"; else good "Bucket is gone"; fi
  recap
  echo
  printf '  %s%s  All clean. Nothing is running and nothing will be billed.%s %s(%ss)%s\n\n' "$BOLD$GREEN" "$OKI" "$RST" "$GRAY" "$((SECONDS - SCRIPT_START))" "$RST"
}

case "$CMD" in
  deploy)   cmd_deploy ;;
  install-cli) cmd_install_cli ;;
  status)   cmd_status ;;
  whoami)   cmd_whoami ;;
  login)    cmd_login ;;
  url)      cmd_url ;;
  logs)     cmd_logs ;;
  destroy)  cmd_destroy ;;
  scaffold) banner; roadmap "Writing the project files"
            step "Writing app.py, index.html and template.yaml into $PROJECT_DIR/ (existing files are kept)."
            scaffold; echo ;;
  help)     usage ;;
  *)        echo "Unknown command: $CMD" >&2; usage >&2; exit 2 ;;
esac
