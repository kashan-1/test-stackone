# Use official Jenkins LTS image
FROM jenkins/jenkins:lts

USER root

# Copy plugin list
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt

# Install plugins + packages + AWS CLI v2
RUN apt-get update && \
    apt-get install -y unzip curl python3 && \
    jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt && \
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install && \
    rm -rf awscliv2.zip aws && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Expose default Jenkins ports
EXPOSE 8080 50000

# Jenkins home volume
VOLUME ["/var/jenkins_home"]

# Switch back to Jenkins user
USER jenkins

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/jenkins.sh"]