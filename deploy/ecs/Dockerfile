# Locust Load Testing Image for DHT Cache Throughput Testing
FROM locustio/locust:2.20.0

# Copy the test script
COPY locustfile.py /mnt/locust/locustfile.py

WORKDIR /mnt/locust

# Default command (overridden by task definition)
CMD ["-f", "/mnt/locust/locustfile.py"]

