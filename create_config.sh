#!/bin/bash

cat > "config.js" << EOF
/* SPHERE.IO credentials */
exports.config = {
  client_id: "${SPHERE_CLIENT_ID}",
  client_secret: "${SPHERE_CLIENT_SECRET}",
  project_key: "${SPHERE_PROJECT_KEY}",
}
EOF

echo "${SPHERE_PROJECT_KEY}:${SPHERE_CLIENT_ID}:${SPHERE_CLIENT_SECRET}" > ".sphere-credentials"
