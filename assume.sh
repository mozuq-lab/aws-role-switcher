#!/usr/bin/env bash
# assume.sh  ―  cross-account や MFA 用の一時クレデンシャルを取得して export する
#
# 使い方） source ./assume.sh [role-arn] [session-name] [mfa-arn] [profile]
#   引数はすべて任意。実行すると role-arn → session-name → mfa-arn → profile の順に
#   対話的に尋ねる。引数を渡した項目は [既定値] として表示され、Enter で確定できる。
#   例）  source ./assume.sh                                   # 全部プロンプトで入力
#        source ./assume.sh arn:aws:iam::999999999999:role/Admin cli-demo
#
# jq と AWS CLI が入っている前提

set -o pipefail

# このスクリプトは取得したクレデンシャルを呼び出し元シェルへ export する設計のため
# source して使う前提。直接実行（./assume.sh）すると別プロセスになり export が消える上、
# 各所の `return` がエラーになって処理が止まらず誤動作するので、ここで明示的に弾く。
if [[ -n "${ZSH_VERSION:-}" ]]; then
    case "${ZSH_EVAL_CONTEXT:-}" in
        *:file) _sourced=1 ;;   # source されたとき末尾が :file になる
        *)      _sourced=0 ;;
    esac
else
    [[ "${BASH_SOURCE[0]}" != "$0" ]] && _sourced=1 || _sourced=0
fi
if [[ "$_sourced" -ne 1 ]]; then
    echo "このスクリプトは source して使ってください（export を現在のシェルへ反映するため）:" >&2
    echo "  source ./assume.sh <role-arn> <session-name> [mfa-serial] [profile]" >&2
    exit 1
fi
unset _sourced

# 引数があれば既定値として使い、実行後に対話的に確認・入力する。
# （長い ARN を毎回打たなくてよいよう、プロンプトで順に尋ねる形。
#   引数を渡した項目は [既定値] が表示され、Enter で確定できる）
DEF_ROLE_ARN="${1:-}"
DEF_SESSION="${2:-}"
DEF_MFA_ARN="${3:-}"
DEF_PROFILE="${4:-}"
DURATION=3600             # 1 時間

# ラベルと既定値を出して 1 行読む小ヘルパー（bash/zsh 両対応のため echo+read で実装）。
# プロンプトは stderr、入力は /dev/tty、値は stdout に返すので $(...) で受けられる。
_assume_ask() {
    local _label="$1" _def="$2" _ans
    if [[ -n "$_def" ]]; then
        echo -n "$_label [$_def]: " >&2
    else
        echo -n "$_label: " >&2
    fi
    read -r _ans </dev/tty
    printf '%s' "${_ans:-$_def}"
}

# role-arn（必須）: 空のうちは聞き直す
ROLE_ARN=$(_assume_ask "role-arn" "$DEF_ROLE_ARN")
while [[ -z "$ROLE_ARN" ]]; do
    echo "role-arn は必須です。" >&2
    ROLE_ARN=$(_assume_ask "role-arn" "$DEF_ROLE_ARN")
done

# session-name（必須）: 2〜64 文字・使用可能文字 [A-Za-z0-9+=,.@_-] のみ
SESSION=$(_assume_ask "session-name" "$DEF_SESSION")
while [[ ! "$SESSION" =~ ^[A-Za-z0-9+=,.@_-]{2,64}$ ]]; do
    echo "session-name は 2〜64 文字・使用可能文字 [A-Za-z0-9+=,.@_-] です。" >&2
    SESSION=$(_assume_ask "session-name" "$DEF_SESSION")
done

# mfa-arn（任意）: Enter でスキップ＝MFA なし
MFA_ARN=$(_assume_ask "mfa-arn（任意・Enter でスキップ）" "$DEF_MFA_ARN")

# profile（任意）: Enter でスキップ＝既定の資格情報を使用
PROFILE=$(_assume_ask "profile（任意・Enter でスキップ）" "$DEF_PROFILE")

unset -f _assume_ask
unset DEF_ROLE_ARN DEF_SESSION DEF_MFA_ARN DEF_PROFILE

# 入力内容のサマリ（確認用）
echo "→ role-arn=$ROLE_ARN / session-name=$SESSION${MFA_ARN:+ / mfa-arn=$MFA_ARN}${PROFILE:+ / profile=$PROFILE}" >&2

# MFA とプロファイルのオプションは配列で構築する。
# 文字列に詰めて未クォートで単語分割に頼ると、値に空白が混じった瞬間に壊れるため。
MFA_OPTIONS=()
if [[ -n "$MFA_ARN" ]]; then
    echo -n 'MFA code: ' >&2
    read -r MFA_CODE </dev/tty
    MFA_OPTIONS=(--serial-number "$MFA_ARN" --token-code "$MFA_CODE")
fi

# プロファイルはこの呼び出しにだけ効かせる（AWS_PROFILE を export しないことで
# シェルを汚さず、AssumeRole 失敗時にも設定を残さない）。
# さらに、前回 source した際の一時クレデンシャルが環境に残っていると
# --profile より優先されてプロファイルが無視されるため、この呼び出しに限り除外する。
PROFILE_OPTIONS=()
CREDS_ENV=()
if [[ -n "$PROFILE" ]]; then
    PROFILE_OPTIONS=(--profile "$PROFILE")
    CREDS_ENV=(env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY \
                   -u AWS_SESSION_TOKEN -u AWS_EXPIRATION)
fi

JSON=$("${CREDS_ENV[@]}" aws sts assume-role \
        --role-arn "$ROLE_ARN"               \
        --role-session-name "$SESSION"       \
        --duration-seconds "$DURATION"       \
        "${MFA_OPTIONS[@]}"                  \
        "${PROFILE_OPTIONS[@]}"              \
        --output json)

if [[ $? -ne 0 ]]; then
    echo "AssumeRole に失敗しました。" >&2
    return 1
fi

# 取得したクレデンシャルを解析。export する前に妥当性を確認する
# （jq 未インストールや不正な JSON のとき、空文字や "null" を export しないため）。
_AKID=$(jq -r '.Credentials.AccessKeyId'     <<<"$JSON")
_SAK=$( jq -r '.Credentials.SecretAccessKey' <<<"$JSON")
_TOK=$( jq -r '.Credentials.SessionToken'    <<<"$JSON")
_EXP=$( jq -r '.Credentials.Expiration'      <<<"$JSON")   # ISO-8601

if [[ -z "$_AKID" || "$_AKID" == "null" ]]; then
    echo "クレデンシャルの解析に失敗しました（jq は入っていますか？）。" >&2
    unset JSON _AKID _SAK _TOK _EXP MFA_CODE
    return 1
fi

export AWS_ACCESS_KEY_ID="$_AKID"
export AWS_SECRET_ACCESS_KEY="$_SAK"
export AWS_SESSION_TOKEN="$_TOK"
export AWS_EXPIRATION="$_EXP"

# 秘密情報を含む一時変数をシェルに残さない
unset JSON _AKID _SAK _TOK _EXP MFA_CODE

echo "AssumeRole 成功。$AWS_EXPIRATION まで有効です。"
echo "確認）  aws sts get-caller-identity"
