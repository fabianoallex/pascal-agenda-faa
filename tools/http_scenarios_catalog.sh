#!/bin/sh
# Services and professionals over HTTP, sourced by tools/http_scenarios.sh
# (it defines req, the checks, $T, and the access tokens $ACCESS (demo's
# owner), $STAFF_ACCESS (demo's staff) and $OTHER_ACCESS (other's owner)).
#
# Bodies with accents go through a file with explicit UTF-8 bytes
# (printf '\303\247'): curl.exe on Windows gets its arguments in the ANSI
# code page (pascal-api-infra-faa's CLAUDE.md).

OWNER="Authorization: Bearer $ACCESS"
STAFF="Authorization: Bearer $STAFF_ACCESS"
OTHER="Authorization: Bearer $OTHER_ACCESS"
# post_file PATH AUTH: POST $T/in.json
post_file() { req POST "$1" "" -H 'Content-Type: application/json' --data-binary "@$T/in.json" -H "$2"; }
patch_file() { req PATCH "$1" "" -H 'Content-Type: application/json' --data-binary "@$T/in.json" -H "$2"; }
id_of() { sed -n 's/.*"id":"\([0-9a-f]*\)".*/\1/p' "$T/body"; }

# --- services: who may write
req POST /services '{"name":"Corte","durationMinutes":30,"price":50}' -H "$STAFF"
status_is 403 "services: staff can't create"
body_is '{"error":"Only the tenant'"'"'s owner can change this.","code":"owner_only"}' "services: owner_only"

req POST /services '{"name":"Corte de Cabelo","durationMinutes":45,"bufferMinutes":10,"price":80.5}' -H "$OWNER"
status_is 201 "services: create"
body_has '"name":"Corte de Cabelo","durationMinutes":45,"bufferMinutes":10,"price":80.5,"active":true' "services: create, the stored values"
CUT="$(id_of)"
printf '{"name":"Colora\303\247\303\243o","durationMinutes":120,"price":250}' > "$T/in.json"
post_file /services "$OWNER"
status_is 201 "services: create, accented name"
body_has "$(printf '"name":"Colora\303\247\303\243o"')" "services: the accented name, as UTF-8"
body_has '"bufferMinutes":0' "services: buffer defaults to 0"
COLOR="$(id_of)"
req POST /services '{"name":"Barba","durationMinutes":20,"price":35.99}' -H "$OWNER"
status_is 201 "services: create a third"
BEARD="$(id_of)"

# The name is unique by its search key: case, spaces and accents don't count.
req POST /services '{"name":"  corte DE cabelo ","durationMinutes":30,"price":1}' -H "$OWNER"
status_is 409 "services: the same name, other case and spaces"
printf '{"name":"Corte de Cab\303\251lo","durationMinutes":30,"price":1}' > "$T/in.json"
post_file /services "$OWNER"
status_is 409 "services: the same name with an accent"

# Validation
req POST /services '{"name":"X","durationMinutes":7,"price":1}' -H "$OWNER"
status_is 400 "services: duration not a multiple of 5"
body_has 'durationMinutes' "services: duration, named"
req POST /services '{"name":"X","durationMinutes":30,"price":1.234}' -H "$OWNER"
status_is 400 "services: a fraction of a cent"
body_has 'fraction of a cent' "services: a fraction of a cent, said"
req POST /services '{"name":"   ","durationMinutes":30,"price":1}' -H "$OWNER"
status_is 400 "services: a blank name"
body_is '{"error":"\"name\" is required.","code":"name_required"}' "services: a blank name, its code"
req POST /services '{"name":"X","durationMinutes":30,"bufferMinutes":121,"price":1}' -H "$OWNER"
status_is 400 "services: buffer too long"
req POST /services '{"name":"X","durationMinutes":30,"price":-1}' -H "$OWNER"
status_is 400 "services: a negative price"
req POST /services "{\"name\":\"$(printf '%0101d' 0)\",\"durationMinutes\":30,\"price\":1}" -H "$OWNER"
status_is 400 "services: a name of 101 characters"
req POST /services '{"name":"X","durationMinutes":30,"price":1,"color":"red"}' -H "$OWNER"
status_is 400 "services: an unknown member"

# Reading: any user of the tenant
req GET /services "" -H "$STAFF"
status_is 200 "services: staff lists"
body_has '"page":1,"limit":20,"total":3,"totalPages":1,"hasNext":false,"hasPrev":false' "services: the page"
body_has '"items":[{"id":"'"$BEARD"'","name":"Barba"' "services: by name, by default"
req GET "/services?search=COLORACAO" "" -H "$STAFF"
body_has '"total":1,' "services: search ignores case and accents"
body_has "\"id\":\"$COLOR\"" "services: search finds the accented name"
req GET "/services?search=de%20cab" "" -H "$STAFF"
body_has '"total":1,' "services: search inside the name"
req GET "/services?search=%25" "" -H "$STAFF"
body_has '"total":0,' "services: a % is literal, not a wildcard"
req GET "/services?orderBy=-price&limit=1" "" -H "$STAFF"
body_has '"limit":1,"total":3,"totalPages":3,"hasNext":true' "services: limit 1"
body_has "\"items\":[{\"id\":\"$COLOR\"" "services: the most expensive first"
req GET "/services?orderBy=duration" "" -H "$STAFF"
body_has "\"items\":[{\"id\":\"$BEARD\"" "services: by duration"
req GET "/services?orderBy=createdAt" "" -H "$STAFF"
status_is 400 "services: an order field not allowed"
req GET "/services?active=maybe" "" -H "$STAFF"
status_is 400 "services: active must be true or false"
req GET "/services?limit=abc" "" -H "$STAFF"
status_is 400 "services: limit not a number"
req GET "/services/$CUT" "" -H "$STAFF"
status_is 200 "services: one"
body_has '"price":80.5' "services: one, its price"
req GET "/services/nothing" "" -H "$STAFF"
status_is 404 "services: an unknown id"

# Changing
req PATCH "/services/$CUT" '{"price":99.9,"active":false}' -H "$OWNER"
status_is 200 "services: patch"
body_has '"name":"Corte de Cabelo","durationMinutes":45,"bufferMinutes":10,"price":99.9,"active":false' "services: patch changed only what came"
req GET "/services?active=false" "" -H "$STAFF"
body_has '"total":1,' "services: only the inactive"
req GET "/services?active=true" "" -H "$STAFF"
body_has '"total":2,' "services: only the active"
# A search and a filter together: with ESCAPE '' SQLdb lost the parameter
# after it and this was a 500 (pascal-db-faa's gotcha 26; fixed with
# PdbLikeContains and ESCAPE '!').
req GET "/services?search=c&active=true" "" -H "$STAFF"
status_is 200 "services: search and active together"
body_has '"total":1,' "services: search and active together, the right row"
req PATCH "/services/$CUT" '{"name":"barba"}' -H "$OWNER"
status_is 409 "services: patch to another service's name"
req PATCH "/services/$CUT" '{}' -H "$OWNER"
status_is 200 "services: an empty patch"
req PATCH "/services/$CUT" '{"price":1}' -H "$STAFF"
status_is 403 "services: staff can't patch"
req PATCH "/services/nothing" '{"price":1}' -H "$OWNER"
status_is 404 "services: patch an unknown id"

# Another tenant sees nothing of demo's.
req GET /services "" -H "$OTHER"
body_has '"total":0,' "services: other tenant's list is its own"
req GET "/services/$CUT" "" -H "$OTHER"
status_is 404 "services: other tenant can't read demo's"
req PATCH "/services/$CUT" '{"price":1}' -H "$OTHER"
status_is 404 "services: other tenant can't change demo's"
req DELETE "/services/$CUT" "" -H "$OTHER"
status_is 404 "services: other tenant can't delete demo's"
req POST /services '{"name":"Corte de Cabelo","durationMinutes":45,"price":80}' -H "$OTHER"
status_is 201 "services: the same name in another tenant"

# Deleting
req DELETE "/services/$BEARD" "" -H "$STAFF"
status_is 403 "services: staff can't delete"
req DELETE "/services/$BEARD" "" -H "$OWNER"
status_is 204 "services: delete"
req GET "/services/$BEARD" "" -H "$OWNER"
status_is 404 "services: deleted"
req DELETE "/services/$BEARD" "" -H "$OWNER"
status_is 404 "services: delete again"

# --- professionals
req POST /professionals '{"name":"Ana Souza","email":"  Ana@Demo.Test "}' -H "$OWNER"
status_is 201 "professionals: create"
body_has '"name":"Ana Souza","email":"ana@demo.test","active":true' "professionals: the email normalized"
ANA="$(id_of)"
printf '{"name":"Jo\303\243o Concei\303\247\303\243o"}' > "$T/in.json"
post_file /professionals "$OWNER"
status_is 201 "professionals: create without an email"
body_has '"email":null' "professionals: no email is null"
JOAO="$(id_of)"
req POST /professionals '{"name":"Ana Souza"}' -H "$OWNER"
status_is 201 "professionals: names may repeat"
req POST /professionals '{"name":"Bia","email":"not-an-email"}' -H "$OWNER"
status_is 400 "professionals: an invalid email"
req POST /professionals '{"name":"Bia"}' -H "$STAFF"
status_is 403 "professionals: staff can't create"

req GET "/professionals?search=conceicao" "" -H "$STAFF"
body_has '"total":1,' "professionals: search ignores accents"
body_has "\"id\":\"$JOAO\"" "professionals: search finds him"
req GET "/professionals?search=souza" "" -H "$STAFF"
body_has '"total":2,' "professionals: two with the same name"

req PATCH "/professionals/$ANA" '{"email":null}' -H "$OWNER"
status_is 200 "professionals: patch the email to null"
body_has '"name":"Ana Souza","email":null' "professionals: null clears the email"
req PATCH "/professionals/$ANA" '{"email":"ana.souza@demo.test"}' -H "$OWNER"
body_has '"email":"ana.souza@demo.test"' "professionals: a new email"
req PATCH "/professionals/$ANA" '{"active":false}' -H "$OWNER"
body_has '"email":"ana.souza@demo.test","active":false' "professionals: absent leaves the email"
req PATCH "/professionals/$ANA" '{"email":"nope"}' -H "$OWNER"
status_is 400 "professionals: patch an invalid email"
req PATCH "/professionals/$ANA" '{"name":null}' -H "$OWNER"
status_is 400 "professionals: the name can't be null"

req GET "/professionals/$ANA" "" -H "$OTHER"
status_is 404 "professionals: other tenant can't read demo's"
req DELETE "/professionals/$JOAO" "" -H "$OTHER"
status_is 404 "professionals: other tenant can't delete demo's"
req DELETE "/professionals/$JOAO" "" -H "$OWNER"
status_is 204 "professionals: delete"
req GET "/professionals?orderBy=-createdAt" "" -H "$STAFF"
status_is 200 "professionals: order by creation"
body_has '"total":2,' "professionals: after the delete"
