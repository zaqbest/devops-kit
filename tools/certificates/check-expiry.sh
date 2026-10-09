#!/bin/bash

################################################################################
# Certificate Expiration Checker with Notification Support
# 
# This script checks SSL/TLS certificate expiration dates and sends notifications
# if the certificate will expire within a specified number of days.
#
# Usage:
#   ./check_cert.sh --cert-path /path/to/cert.pem --days 30
#   ./check_cert.sh --cert-path /path/to/cert.pem --days 30 --notify-email user@example.com
#   ./check_cert.sh -c /path/to/cert.pem -d 30
#
# Requirements:
#   - openssl command must be available
#   - For email notifications: mail/mailx command (optional)
#   - For webhook notifications: curl command (optional)
################################################################################

set -e

# Color codes for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Default values
CERT_PATH=""
DAYS_THRESHOLD=""
NOTIFY_EMAIL=""
WEBHOOK_URL=""
QUIET=0

# Function to display usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Check SSL/TLS certificate expiration and send notifications.

OPTIONS:
    -c, --cert-path PATH      Path to certificate file (required)
    -d, --days DAYS           Days threshold for notification (required)
    -e, --notify-email EMAIL  Email address for notifications (optional)
    -w, --webhook URL         Webhook URL for notifications (optional)
    -q, --quiet               Suppress normal output, only show errors
    -h, --help                Display this help message

EXAMPLES:
    $0 --cert-path /etc/ssl/cert.pem --days 30
    $0 -c /etc/ssl/cert.pem -d 30 -e admin@example.com
    $0 -c /etc/ssl/cert.pem -d 30 -w https://hooks.slack.com/services/xxx

ENVIRONMENT VARIABLES:
    SMTP_SERVER     SMTP server for email (default: localhost)
    SMTP_FROM       From address for email (default: cert-checker@localhost)

EOF
    exit 1
}

# Function to log messages
log() {
    if [ $QUIET -eq 0 ]; then
        echo -e "$1"
    fi
}

# Function to log errors (always shown)
log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Function to log warnings
log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Function to log success
log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--cert-path)
            CERT_PATH="$2"
            shift 2
            ;;
        -d|--days)
            DAYS_THRESHOLD="$2"
            shift 2
            ;;
        -e|--notify-email)
            NOTIFY_EMAIL="$2"
            shift 2
            ;;
        -w|--webhook)
            WEBHOOK_URL="$2"
            shift 2
            ;;
        -q|--quiet)
            QUIET=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required arguments
if [ -z "$CERT_PATH" ]; then
    log_error "Certificate path is required"
    usage
fi

if [ -z "$DAYS_THRESHOLD" ]; then
    log_error "Days threshold is required"
    usage
fi

# Validate days threshold is a number
if ! [[ "$DAYS_THRESHOLD" =~ ^[0-9]+$ ]]; then
    log_error "Days threshold must be a positive integer"
    exit 1
fi

# Check if openssl is available
if ! command -v openssl &> /dev/null; then
    log_error "openssl command not found. Please install openssl."
    exit 1
fi

# Check if certificate file exists
if [ ! -f "$CERT_PATH" ]; then
    log_error "Certificate file not found: $CERT_PATH"
    exit 1
fi

# Function to check certificate expiration
check_certificate() {
    local cert_path="$1"
    local days_threshold="$2"
    
    log "Checking certificate: $cert_path"
    
    # Get certificate end date
    local end_date=$(openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2)
    
    if [ -z "$end_date" ]; then
        log_error "Failed to read certificate. File may be corrupted or in wrong format."
        exit 1
    fi
    
    # Get certificate subject (Common Name)
    local subject=$(openssl x509 -subject -noout -in "$cert_path" 2>/dev/null | sed -n 's/.*CN = \(.*\)/\1/p')
    if [ -z "$subject" ]; then
        subject=$(openssl x509 -subject -noout -in "$cert_path" 2>/dev/null | sed -n 's/.*CN=\(.*\)/\1/p')
    fi
    if [ -z "$subject" ]; then
        subject="Unknown"
    fi
    
    # Get issuer
    local issuer=$(openssl x509 -issuer -noout -in "$cert_path" 2>/dev/null | sed -n 's/.*CN = \(.*\)/\1/p')
    if [ -z "$issuer" ]; then
        issuer=$(openssl x509 -issuer -noout -in "$cert_path" 2>/dev/null | sed -n 's/.*CN=\(.*\)/\1/p')
    fi
    if [ -z "$issuer" ]; then
        issuer="Unknown"
    fi
    
    # Convert end date to epoch time
    local end_epoch=$(date -j -f "%b %d %T %Y %Z" "$end_date" "+%s" 2>/dev/null || date -d "$end_date" "+%s" 2>/dev/null)
    local current_epoch=$(date "+%s")
    
    # Calculate days remaining
    local seconds_remaining=$((end_epoch - current_epoch))
    local days_remaining=$((seconds_remaining / 86400))
    
    # Determine status
    local status=""
    local urgency=""
    local exit_code=0
    
    if [ $days_remaining -lt 0 ]; then
        status="🔴 EXPIRED"
        urgency="CRITICAL"
        exit_code=2
    elif [ $days_remaining -le 7 ]; then
        status="🔴 EXPIRING SOON"
        urgency="URGENT"
        exit_code=1
    elif [ $days_remaining -le $days_threshold ]; then
        status="⚠️  NEEDS RENEWAL"
        urgency="WARNING"
        exit_code=1
    else
        status="✅ VALID"
        urgency="INFO"
        exit_code=0
    fi
    
    # Create message
    local message="Certificate Status: $status
Urgency: $urgency

Certificate: $subject
Issuer: $issuer
Valid Until: $end_date
Days Remaining: $days_remaining
Threshold: $days_threshold days

File Path: $cert_path"
    
    # Display result
    if [ $days_remaining -lt 0 ]; then
        log_error "Certificate has EXPIRED!"
    elif [ $days_remaining -le $days_threshold ]; then
        log_warning "Certificate will expire in $days_remaining days"
    else
        log_success "Certificate is valid for $days_remaining more days"
    fi
    
    log ""
    log "$message"
    log ""
    
    # Send notifications if needed
    if [ $days_remaining -le $days_threshold ]; then
        send_notifications "$message" "$status" "$subject" "$days_remaining"
    fi
    
    return $exit_code
}

# Function to send email notification
send_email_notification() {
    local message="$1"
    local subject_line="$2"
    local email="$3"
    
    if [ -z "$email" ]; then
        return 0
    fi
    
    local smtp_from="${SMTP_FROM:-cert-checker@localhost}"
    
    log "Sending email notification to: $email"
    
    if command -v mail &> /dev/null; then
        echo "$message" | mail -s "$subject_line" "$email"
        log_success "Email notification sent"
    elif command -v mailx &> /dev/null; then
        echo "$message" | mailx -s "$subject_line" "$email"
        log_success "Email notification sent"
    else
        log_warning "mail/mailx command not found. Email notification skipped."
        log_warning "Install mailutils or mailx package to enable email notifications."
    fi
}

# Function to send webhook notification
send_webhook_notification() {
    local message="$1"
    local status="$2"
    local cert_name="$3"
    local days="$4"
    local webhook="$5"
    
    if [ -z "$webhook" ]; then
        return 0
    fi
    
    log "Sending webhook notification to: $webhook"
    
    if ! command -v curl &> /dev/null; then
        log_warning "curl command not found. Webhook notification skipped."
        return 1
    fi
    
    # Create JSON payload (generic format that works with most webhooks)
    local json_payload=$(cat <<EOF
{
  "device_key": "yWdgHLf7TESVmuyhQgV6mh",
  "title": "Certificate Alert",
  "body": "Certificate '$cert_name' on $(hostname) is $status with $days days remaining."
}
EOF
)
    
    # Try to send webhook
    local response=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d "$json_payload" "$webhook" 2>&1)
    local http_code=$(echo "$response" | tail -n1)
    
    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        log_success "Webhook notification sent successfully"
    else
        log_warning "Webhook notification failed (HTTP $http_code)"
    fi
}

# Function to send all notifications
send_notifications() {
    local message="$1"
    local status="$2"
    local cert_name="$3"
    local days="$4"
    
    local subject_line="Certificate Alert: $status - $cert_name ($days days remaining)"
    
    # Send email if configured
    if [ -n "$NOTIFY_EMAIL" ]; then
        send_email_notification "$message" "$subject_line" "$NOTIFY_EMAIL"
    fi
    
    # Send webhook if configured
    if [ -n "$WEBHOOK_URL" ]; then
        send_webhook_notification "$message" "$status" "$cert_name" "$days" "$WEBHOOK_URL"
    fi
    
    # If no notification method configured, just log
    if [ -z "$NOTIFY_EMAIL" ] && [ -z "$WEBHOOK_URL" ]; then
        log_warning "No notification method configured. Use -e or -w option to enable notifications."
    fi
}

# Main execution
main() {
    log "========================================="
    log "Certificate Expiration Checker"
    log "========================================="
    log ""
    
    check_certificate "$CERT_PATH" "$DAYS_THRESHOLD"
    exit_code=$?
    
    log ""
    log "========================================="
    log "Check completed"
    log "========================================="
    
    exit $exit_code
}

# Run main function
main