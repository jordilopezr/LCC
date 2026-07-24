#!/bin/bash
# SFTP Security Testing Helper Script
# Usage: ./test_helpers.sh [command]

set -e

# Cambiar al directorio raíz del proyecto
cd "$(dirname "$0")/.."

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "\n${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

# Test #3: Create files with dangerous names
create_dangerous_files() {
    print_header "Creating Test Files with Dangerous Names"

    cd /tmp

    # Command injection attempts
    touch 'test;rm -rf.txt' 2>/dev/null && print_success "Created: test;rm -rf.txt"
    touch 'report$(whoami).pdf' 2>/dev/null && print_success "Created: report\$(whoami).pdf"
    touch 'file|cat passwd.txt' 2>/dev/null && print_success "Created: file|cat passwd.txt"
    touch 'file&echo hacked.txt' 2>/dev/null && print_success "Created: file&echo hacked.txt"
    touch 'test`id`.log' 2>/dev/null && print_success "Created: test\`id\`.log"

    # Path traversal attempts
    touch '../../../etc/passwd.copy' 2>/dev/null && print_success "Created: ../../../etc/passwd.copy"
    touch 'file\\windows\\system32.txt' 2>/dev/null && print_success "Created: file\\\\windows\\\\system32.txt"

    # Null byte injection
    # Note: Might not work on all filesystems
    # touch $'file\x00hidden.txt' 2>/dev/null && print_success "Created: file\x00hidden.txt"

    print_success "\nDangerous test files created in /tmp/"
    echo -e "Try uploading these files via SFTP browser to test sanitization\n"

    ls -la /tmp/test* /tmp/report* /tmp/file* 2>/dev/null | head -20
}

# Test #4: Create test files of various sizes
create_size_test_files() {
    print_header "Creating Size Test Files"

    cd /tmp

    # Small file (1MB)
    if [ ! -f test_1mb.bin ]; then
        dd if=/dev/zero of=test_1mb.bin bs=1M count=1 2>/dev/null
        print_success "Created: test_1mb.bin (1 MB)"
    else
        print_warning "test_1mb.bin already exists"
    fi

    # Medium file (100MB)
    if [ ! -f test_100mb.bin ]; then
        print_warning "Creating 100MB file... (this may take a moment)"
        dd if=/dev/zero of=test_100mb.bin bs=1M count=100 2>/dev/null
        print_success "Created: test_100mb.bin (100 MB)"
    else
        print_warning "test_100mb.bin already exists"
    fi

    # Large file (1GB) - optional
    read -p "Create 1GB test file? This will take disk space. (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if [ ! -f test_1gb.bin ]; then
            print_warning "Creating 1GB file... (this will take time)"
            dd if=/dev/zero of=test_1gb.bin bs=1M count=1024 2>/dev/null
            print_success "Created: test_1gb.bin (1 GB)"
        else
            print_warning "test_1gb.bin already exists"
        fi
    fi

    # Very large file (11GB) - exceeds limit
    read -p "Create 11GB test file to test limit? This requires 11GB disk space. (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if [ ! -f test_11gb.bin ]; then
            print_warning "Creating 11GB file... (this will take significant time)"
            print_warning "You can press Ctrl+C to cancel"
            dd if=/dev/zero of=test_11gb.bin bs=1G count=11 2>/dev/null
            print_success "Created: test_11gb.bin (11 GB)"
        else
            print_warning "test_11gb.bin already exists"
        fi
    fi

    print_success "\nTest files created in /tmp/"
    ls -lh /tmp/test_*.bin 2>/dev/null
}

# Test #6: SSH Authentication testing
test_ssh_auth() {
    print_header "SSH Authentication Testing Helper"

    print_warning "This will temporarily disable SSH authentication!"
    print_warning "Make sure you can restore it afterwards."
    read -p "Continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi

    # Backup current SSH key
    if [ -f ~/.ssh/id_rsa ]; then
        print_warning "Backing up SSH key..."
        cp ~/.ssh/id_rsa ~/.ssh/id_rsa.testing_backup
        print_success "Backed up to: ~/.ssh/id_rsa.testing_backup"
    fi

    # Kill ssh-agent
    print_warning "Killing ssh-agent..."
    killall ssh-agent 2>/dev/null || print_warning "ssh-agent not running"
    unset SSH_AUTH_SOCK
    unset SSH_AGENT_PID

    # Rename SSH key
    if [ -f ~/.ssh/id_rsa ]; then
        print_warning "Renaming SSH key to make it unavailable..."
        mv ~/.ssh/id_rsa ~/.ssh/id_rsa.hidden
        print_success "SSH key hidden"
    fi

    print_success "\nSSH authentication disabled!"
    echo -e "\n${YELLOW}Now try to open SFTP in the app.${NC}"
    echo -e "${YELLOW}You should see detailed error messages about:${NC}"
    echo -e "  • SSH agent failure"
    echo -e "  • SSH key file not found"
    echo -e "  • Troubleshooting steps"
    echo -e "\n${RED}Press ENTER when you've tested and want to restore SSH...${NC}"
    read

    # Restore
    restore_ssh_auth
}

restore_ssh_auth() {
    print_header "Restoring SSH Authentication"

    # Restore SSH key
    if [ -f ~/.ssh/id_rsa.hidden ]; then
        mv ~/.ssh/id_rsa.hidden ~/.ssh/id_rsa
        print_success "SSH key restored"
    fi

    # Restore from backup if exists
    if [ -f ~/.ssh/id_rsa.testing_backup ]; then
        if [ ! -f ~/.ssh/id_rsa ]; then
            cp ~/.ssh/id_rsa.testing_backup ~/.ssh/id_rsa
            print_success "SSH key restored from backup"
        fi
        rm ~/.ssh/id_rsa.testing_backup
    fi

    # Restart ssh-agent
    eval "$(ssh-agent -s)" >/dev/null
    print_success "ssh-agent started"

    # Add key
    if [ -f ~/.ssh/id_rsa ]; then
        ssh-add ~/.ssh/id_rsa 2>/dev/null
        print_success "SSH key added to agent"
    fi

    print_success "\nSSH authentication restored!"
}

# Cleanup test files
cleanup() {
    print_header "Cleaning Up Test Files"

    cd /tmp

    # Remove dangerous filename test files
    rm -f test\;* report\$* file\|* file\&* test\`* 2>/dev/null
    rm -f ../../../etc/passwd.copy 2>/dev/null

    # Remove size test files
    read -p "Remove size test files (test_*.bin)? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -f test_*.bin
        print_success "Size test files removed"
    fi

    # Restore SSH if needed
    if [ -f ~/.ssh/id_rsa.hidden ] || [ -f ~/.ssh/id_rsa.testing_backup ]; then
        restore_ssh_auth
    fi

    print_success "Cleanup complete!"
}

# Run the app
run_app() {
    print_header "Starting Lightweight Cloud Connector"

    APP_PATH="./build/linux/x64/debug/bundle/lightweight_cloud_connector"

    if [ ! -f "$APP_PATH" ]; then
        print_error "App not found at: $APP_PATH"
        print_warning "Run: flutter build linux --debug"
        exit 1
    fi

    print_success "Starting app..."
    echo -e "${YELLOW}Watch console output for error messages and logs${NC}\n"

    $APP_PATH
}

# Show menu
show_menu() {
    print_header "SFTP Security Testing Helper"

    echo "Available commands:"
    echo ""
    echo "  ${GREEN}dangerous-files${NC}    Create files with dangerous names (Test #3)"
    echo "  ${GREEN}size-files${NC}        Create files of various sizes (Test #4)"
    echo "  ${GREEN}test-ssh${NC}          Test SSH auth error messages (Test #6)"
    echo "  ${GREEN}restore-ssh${NC}       Restore SSH authentication"
    echo "  ${GREEN}cleanup${NC}           Clean up all test files"
    echo "  ${GREEN}run${NC}               Start the application"
    echo ""
    echo "Usage: ./scripts/test_helpers.sh [command]"
    echo "Example: ./scripts/test_helpers.sh dangerous-files"
    echo ""
}

# Main
case "$1" in
    dangerous-files)
        create_dangerous_files
        ;;
    size-files)
        create_size_test_files
        ;;
    test-ssh)
        test_ssh_auth
        ;;
    restore-ssh)
        restore_ssh_auth
        ;;
    cleanup)
        cleanup
        ;;
    run)
        run_app
        ;;
    *)
        show_menu
        ;;
esac
