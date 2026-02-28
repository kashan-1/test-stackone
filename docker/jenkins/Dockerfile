# Use official Jenkins LTS image
FROM jenkins/jenkins:lts

USER root

# Copy plugin list
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt

# Install packages, plugins, and AWS CLI v2 dynamically based on architecture
RUN set -eux; \
    # Install necessary packages
    apt-get update && \
    apt-get install -y unzip curl python3 lsb-release gnupg && \
    \
    # Install Jenkins plugins
    jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt; \
    \
    # Detect architecture
    ARCH=$(uname -m); \
    echo "Detected architecture: $ARCH"; \
    \
    # Set AWS CLI download URL based on architecture
    if [ "$ARCH" = "x86_64" ]; then \
        AWSCLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"; \
    elif [ "$ARCH" = "aarch64" ]; then \
        AWSCLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"; \
    else \
        echo "Unsupported architecture: $ARCH"; exit 1; \
    fi; \
    \
    echo "Downloading AWS CLI v2 for $ARCH from $AWSCLI_URL"; \
    curl -sSL "$AWSCLI_URL" -o awscliv2.zip; \
    unzip awscliv2.zip; \
    ./aws/install; \
    rm -rf awscliv2.zip aws; \
    \
    # Clean up apt cache
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Expose default Jenkins ports
EXPOSE 8080 50000

# Jenkins home volume
VOLUME ["/var/jenkins_home"]

# Switch back to Jenkins user
USER jenkins

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/jenkins.sh"]