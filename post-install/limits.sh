# Increase inotify limits for file watchers as it makes tpm2 enrollment work better

sudo tee /etc/sysctl.d/99-inotify.conf <<'EOF'
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=1024
EOF
sudo sysctl --system