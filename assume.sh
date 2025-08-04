#!/usr/bin/env bash
# assume.sh  ―  cross-account や MFA 用の一時クレデンシャルを取得して export する
#
# 使い方） source ./assume.sh <role-arn> <session-name> [mfa-serial] [profile]
#   例）   source ./assume.sh arn:aws:iam::999999999999:role/Admin cli-demo
#         source ./assume.sh arn:aws:iam::999999999999:role/Admin cli-demo arn:aws:iam::111111111111:mfa/alice
#         source ./assume.sh arn:aws:iam::999999999999:role/Admin cli-demo "" default
#
# jq と AWS CLI が入っている前提

set -o pipefail

ROLE_ARN="${1:-}"
SESSION="${2:-}"

# 必須パラメータチェック
if [[ -z "$ROLE_ARN" ]] || [[ -z "$SESSION" ]]; then
    echo "使い方: source ./assume.sh <role-arn> <session-name> [mfa-serial] [profile]" >&2
    echo "例: source ./assume.sh arn:aws:iam::999999999999:role/Admin cli-demo" >&2
    return 1
fi
MFA_ARN="${3:-}"          # 指定があれば MFA を要求
PROFILE="${4:-}"          # 指定があればプロファイルを使用
DURATION=3600             # 1 時間

# MFA とプロファイルのオプションを構築
MFA_OPTIONS=""
if [[ -n "$MFA_ARN" ]]; then
    echo -n 'MFA code: ' >&2
    read MFA_CODE </dev/tty
    MFA_OPTIONS="--serial-number $MFA_ARN --token-code $MFA_CODE"
fi

# プロファイル指定がある場合は環境変数で設定
if [[ -n "$PROFILE" ]]; then
    export AWS_PROFILE="$PROFILE"
fi

JSON=$(aws sts assume-role                 \
        --role-arn "$ROLE_ARN"             \
        --role-session-name "$SESSION"     \
        --duration-seconds "$DURATION"     \
        $MFA_OPTIONS                       \
        --output json)

if [[ $? -ne 0 ]]; then
    echo "AssumeRole に失敗しました。" >&2
    return 1
fi

# 取得したクレデンシャルを即 export
export AWS_ACCESS_KEY_ID=$(     jq -r '.Credentials.AccessKeyId'     <<<"$JSON")
export AWS_SECRET_ACCESS_KEY=$( jq -r '.Credentials.SecretAccessKey' <<<"$JSON")
export AWS_SESSION_TOKEN=$(     jq -r '.Credentials.SessionToken'    <<<"$JSON")
export AWS_EXPIRATION=$(        jq -r '.Credentials.Expiration'      <<<"$JSON")   # ISO-8601

echo "AssumeRole 成功。$AWS_EXPIRATION まで有効です。"
echo "確認）  aws sts get-caller-identity"
