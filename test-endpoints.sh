#!/bin/bash
# Comprehensive test suite for Koha Alpine Docker CGI endpoints
# Tests both OPAC (8080) and Intranet (8081) endpoints

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

COMPOSE_FILE="docker-compose-alpinekoha.yml"
KOHA_CONTAINER="koha-docker-koha-1"

echo -e "${BLUE}==================================================================${NC}"
echo -e "${BLUE}Koha Alpine Docker Endpoint Test Suite${NC}"
echo -e "${BLUE}==================================================================${NC}"
echo

# Test 1: Container Status
echo -e "${YELLOW}[TEST 1] Checking container status...${NC}"
if docker compose -f "${COMPOSE_FILE}" ps | grep -q "${KOHA_CONTAINER}.*Up"; then
    echo -e "${GREEN}✓ Container is running${NC}"
else
    echo -e "${RED}✗ Container is not running${NC}"
    exit 1
fi
echo

# Test 2: Apache Module Status
echo -e "${YELLOW}[TEST 2] Verifying mod_cgi is loaded...${NC}"
if docker compose -f "${COMPOSE_FILE}" exec koha httpd -M 2>/dev/null | grep -q "cgi_module"; then
    echo -e "${GREEN}✓ mod_cgi module is loaded${NC}"
else
    echo -e "${RED}✗ mod_cgi module is NOT loaded${NC}"
    exit 1
fi
echo

# Test 3: Apache Syntax Validation
echo -e "${YELLOW}[TEST 3] Validating Apache configuration syntax...${NC}"
if docker compose -f "${COMPOSE_FILE}" exec koha httpd -t 2>&1 | grep -q "Syntax OK"; then
    echo -e "${GREEN}✓ Apache configuration syntax is valid${NC}"
else
    echo -e "${RED}✗ Apache configuration has syntax errors${NC}"
    docker compose -f "${COMPOSE_FILE}" exec koha httpd -t 2>&1
    exit 1
fi
echo

# Test 4: Check CGI Handler Directives in OPAC Config
echo -e "${YELLOW}[TEST 4] Verifying CGI directives in OPAC config...${NC}"
OPAC_CONFIG=$(docker compose -f "${COMPOSE_FILE}" exec koha cat /etc/koha/apache-shared-opac-git.conf 2>/dev/null)
if echo "$OPAC_CONFIG" | grep -A 3 'Directory "/kohadevbox/koha"' | grep -q "Options.*ExecCGI"; then
    echo -e "${GREEN}✓ OPAC config has 'Options +ExecCGI'${NC}"
else
    echo -e "${RED}✗ OPAC config missing 'Options +ExecCGI'${NC}"
    exit 1
fi
if echo "$OPAC_CONFIG" | grep -A 3 'Directory "/kohadevbox/koha"' | grep -q "AddHandler.*cgi-script"; then
    echo -e "${GREEN}✓ OPAC config has 'AddHandler cgi-script .pl'${NC}"
else
    echo -e "${RED}✗ OPAC config missing 'AddHandler cgi-script .pl'${NC}"
    exit 1
fi
echo

# Test 5: Check CGI Handler Directives in Intranet Config
echo -e "${YELLOW}[TEST 5] Verifying CGI directives in Intranet config...${NC}"
INTRANET_CONFIG=$(docker compose -f "${COMPOSE_FILE}" exec koha cat /etc/koha/apache-shared-intranet-git.conf 2>/dev/null)
if echo "$INTRANET_CONFIG" | grep -A 3 'Directory "/kohadevbox/koha"' | grep -q "Options.*ExecCGI"; then
    echo -e "${GREEN}✓ Intranet config has 'Options +ExecCGI'${NC}"
else
    echo -e "${RED}✗ Intranet config missing 'Options +ExecCGI'${NC}"
    exit 1
fi
if echo "$INTRANET_CONFIG" | grep -A 3 'Directory "/kohadevbox/koha"' | grep -q "AddHandler.*cgi-script"; then
    echo -e "${GREEN}✓ Intranet config has 'AddHandler cgi-script .pl'${NC}"
else
    echo -e "${RED}✗ Intranet config missing 'AddHandler cgi-script .pl'${NC}"
    exit 1
fi
echo

# Test 6: Port 8080 (OPAC) - Connectivity
echo -e "${YELLOW}[TEST 6] Testing OPAC port 8080 connectivity...${NC}"
if timeout 5 curl -s http://localhost:8080/ >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Port 8080 is responding${NC}"
else
    echo -e "${RED}✗ Port 8080 is not responding${NC}"
    exit 1
fi
echo

# Test 7: Port 8081 (Intranet) - Connectivity
echo -e "${YELLOW}[TEST 7] Testing Intranet port 8081 connectivity...${NC}"
if timeout 5 curl -s http://localhost:8081/ >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Port 8081 is responding${NC}"
else
    echo -e "${RED}✗ Port 8081 is not responding${NC}"
    exit 1
fi
echo

# Test 8: Port 8080 - Check for Perl source code (indicates bug)
echo -e "${YELLOW}[TEST 8] Checking OPAC (8080) response for Perl source code...${NC}"
OPAC_RESPONSE=$(curl -s http://localhost:8080/ 2>&1)
if echo "$OPAC_RESPONSE" | grep -q "#!/usr/bin/perl"; then
    echo -e "${RED}✗ OPAC is serving raw Perl source code (CGI BUG DETECTED)${NC}"
    echo "First 10 lines of response:"
    echo "$OPAC_RESPONSE" | head -10
    exit 1
elif echo "$OPAC_RESPONSE" | grep -q "use Modern::Perl"; then
    echo -e "${RED}✗ OPAC is serving raw Perl source code (CGI BUG DETECTED)${NC}"
    echo "First 10 lines of response:"
    echo "$OPAC_RESPONSE" | head -10
    exit 1
else
    echo -e "${GREEN}✓ OPAC is not serving raw Perl source code${NC}"
fi
echo

# Test 9: Port 8081 - Check for Perl source code (indicates bug)
echo -e "${YELLOW}[TEST 9] Checking Intranet (8081) response for Perl source code...${NC}"
INTRANET_RESPONSE=$(curl -s http://localhost:8081/ 2>&1)
if echo "$INTRANET_RESPONSE" | grep -q "#!/usr/bin/perl"; then
    echo -e "${RED}✗ Intranet is serving raw Perl source code (CGI BUG DETECTED)${NC}"
    echo "First 10 lines of response:"
    echo "$INTRANET_RESPONSE" | head -10
    exit 1
elif echo "$INTRANET_RESPONSE" | grep -q "use Modern::Perl"; then
    echo -e "${RED}✗ Intranet is serving raw Perl source code (CGI BUG DETECTED)${NC}"
    echo "First 10 lines of response:"
    echo "$INTRANET_RESPONSE" | head -10
    exit 1
else
    echo -e "${GREEN}✓ Intranet is not serving raw Perl source code${NC}"
fi
echo

# Test 10: Port 8080 - HTTP Headers and Status
echo -e "${YELLOW}[TEST 10] Checking OPAC (8080) HTTP headers and status...${NC}"
OPAC_HEADERS=$(curl -s -i http://localhost:8080/ 2>&1)
echo "Response headers:"
echo "$OPAC_HEADERS" | head -10
if echo "$OPAC_HEADERS" | grep -q "HTTP/1.1 302"; then
    echo -e "${GREEN}✓ OPAC returns HTTP 302 redirect${NC}"
elif echo "$OPAC_HEADERS" | grep -q "HTTP/1.1 200"; then
    echo -e "${GREEN}✓ OPAC returns HTTP 200 OK${NC}"
else
    echo -e "${YELLOW}! OPAC returns unusual status (check above)${NC}"
fi
echo

# Test 11: Port 8081 - HTTP Headers and Status
echo -e "${YELLOW}[TEST 11] Checking Intranet (8081) HTTP headers and status...${NC}"
INTRANET_HEADERS=$(curl -s -i http://localhost:8081/ 2>&1)
echo "Response headers:"
echo "$INTRANET_HEADERS" | head -10
if echo "$INTRANET_HEADERS" | grep -q "HTTP/1.1 302"; then
    echo -e "${GREEN}✓ Intranet returns HTTP 302 redirect${NC}"
elif echo "$INTRANET_HEADERS" | grep -q "HTTP/1.1 200"; then
    echo -e "${GREEN}✓ Intranet returns HTTP 200 OK${NC}"
else
    echo -e "${YELLOW}! Intranet returns unusual status (check above)${NC}"
fi
echo

# Test 12: Follow OPAC redirect
echo -e "${YELLOW}[TEST 12] Following OPAC redirect and checking target page...${NC}"
OPAC_REDIRECT=$(echo "$OPAC_HEADERS" | grep -i "^Location:" | awk '{print $2}' | tr -d '\r')
if [ -n "$OPAC_REDIRECT" ]; then
    echo "Redirect destination: $OPAC_REDIRECT"
    OPAC_TARGET=$(curl -s http://localhost:8080"$OPAC_REDIRECT" 2>&1 | head -20)
    if echo "$OPAC_TARGET" | grep -q "<!DOCTYPE\|<html\|<HTML"; then
        echo -e "${GREEN}✓ Redirect target returns HTML${NC}"
    elif echo "$OPAC_TARGET" | grep -q "#!/usr/bin/perl\|use Modern::Perl"; then
        echo -e "${RED}✗ Redirect target is serving Perl source code${NC}"
        exit 1
    else
        echo -e "${YELLOW}! Redirect target response type unclear:${NC}"
        echo "$OPAC_TARGET" | head -5
    fi
else
    echo -e "${YELLOW}! No redirect location found${NC}"
fi
echo

# Test 13: Follow Intranet redirect
echo -e "${YELLOW}[TEST 13] Following Intranet redirect and checking target page...${NC}"
INTRANET_REDIRECT=$(echo "$INTRANET_HEADERS" | grep -i "^Location:" | awk '{print $2}' | tr -d '\r')
if [ -n "$INTRANET_REDIRECT" ]; then
    echo "Redirect destination: $INTRANET_REDIRECT"
    INTRANET_TARGET=$(curl -s http://localhost:8081"$INTRANET_REDIRECT" 2>&1 | head -20)
    if echo "$INTRANET_TARGET" | grep -q "<!DOCTYPE\|<html\|<HTML"; then
        echo -e "${GREEN}✓ Redirect target returns HTML${NC}"
    elif echo "$INTRANET_TARGET" | grep -q "#!/usr/bin/perl\|use Modern::Perl"; then
        echo -e "${RED}✗ Redirect target is serving Perl source code${NC}"
        exit 1
    else
        echo -e "${YELLOW}! Redirect target response type unclear:${NC}"
        echo "$INTRANET_TARGET" | head -5
    fi
else
    echo -e "${YELLOW}! No redirect location found${NC}"
fi
echo

# Test 14: Check Apache error logs for CGI execution errors
echo -e "${YELLOW}[TEST 14] Checking Apache error logs for CGI execution issues...${NC}"
ERROR_LOG=$(docker compose -f "${COMPOSE_FILE}" exec koha tail -n 50 /var/log/koha/kohadev/opac-error.log 2>/dev/null)
if echo "$ERROR_LOG" | grep -q "\[cgi:error\]"; then
    echo -e "${GREEN}✓ Apache is executing CGI scripts (cgi:error messages present)${NC}"
    echo "Sample CGI error log entries:"
    echo "$ERROR_LOG" | grep "\[cgi:error\]" | head -3
else
    echo -e "${YELLOW}! No CGI error messages found (CGI might not be executing)${NC}"
    echo "Recent error log entries:"
    echo "$ERROR_LOG" | head -5
fi
echo

# Test 15: Check content type of responses
echo -e "${YELLOW}[TEST 15] Checking response Content-Type headers...${NC}"
OPAC_CONTENT_TYPE=$(curl -s -i http://localhost:8080/ 2>&1 | grep -i "Content-Type")
INTRANET_CONTENT_TYPE=$(curl -s -i http://localhost:8081/ 2>&1 | grep -i "Content-Type")
echo "OPAC Content-Type: $OPAC_CONTENT_TYPE"
echo "Intranet Content-Type: $INTRANET_CONTENT_TYPE"
if echo "$OPAC_CONTENT_TYPE" | grep -q "text/plain"; then
    echo -e "${RED}✗ OPAC serving content as text/plain (likely Perl source)${NC}"
    exit 1
elif echo "$OPAC_CONTENT_TYPE" | grep -q "text/html"; then
    echo -e "${GREEN}✓ OPAC serving HTML content${NC}"
fi
if echo "$INTRANET_CONTENT_TYPE" | grep -q "text/plain"; then
    echo -e "${RED}✗ Intranet serving content as text/plain (likely Perl source)${NC}"
    exit 1
elif echo "$INTRANET_CONTENT_TYPE" | grep -q "text/html"; then
    echo -e "${GREEN}✓ Intranet serving HTML content${NC}"
fi
echo

# Test 16: Check file permissions
echo -e "${YELLOW}[TEST 16] Checking Koha configuration file permissions...${NC}"
KOHA_CONF_PERMS=$(docker compose -f "${COMPOSE_FILE}" exec koha stat -c "%a" /etc/koha/sites/kohadev/koha-conf.xml 2>/dev/null)
echo "koha-conf.xml permissions: $KOHA_CONF_PERMS"
if [ "$KOHA_CONF_PERMS" = "644" ] || [ "$KOHA_CONF_PERMS" = "666" ]; then
    echo -e "${GREEN}✓ koha-conf.xml is world-readable${NC}"
else
    echo -e "${YELLOW}! koha-conf.xml permissions may restrict Apache access${NC}"
fi
echo

# Test 17: Check Apache process and listening ports
echo -e "${YELLOW}[TEST 17] Verifying Apache is listening on configured ports...${NC}"
if docker compose -f "${COMPOSE_FILE}" exec koha netstat -tuln 2>/dev/null | grep -q ":8080\|:8081"; then
    echo -e "${GREEN}✓ Apache is listening on OPAC/Intranet ports${NC}"
else
    echo -e "${YELLOW}! Checking with ss instead...${NC}"
    if docker compose -f "${COMPOSE_FILE}" exec koha ss -tuln 2>/dev/null | grep -q ":8080\|:8081"; then
        echo -e "${GREEN}✓ Apache is listening on OPAC/Intranet ports${NC}"
    else
        echo -e "${YELLOW}! Could not verify listening ports${NC}"
    fi
fi
echo

echo -e "${BLUE}==================================================================${NC}"
echo -e "${GREEN}All tests completed!${NC}"
echo -e "${BLUE}==================================================================${NC}"
