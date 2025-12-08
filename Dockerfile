# Use the official Python image from the Docker Hub
FROM python:3.9-slim

#RUN apt-get update && \
#    apt-get install -y curl && \
#    apt-get clean && \
#    rm -rf /var/lib/apt/lists/*

# Set the working directory in the container
WORKDIR /app

# Copy the requirements file into the container
COPY requirements.txt .

# Install the dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Copy the rest of the application code into the container
COPY . .

# Command to run the script
CMD ["python", "app.py"]