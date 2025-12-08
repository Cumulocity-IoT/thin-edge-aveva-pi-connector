# Configuration Management Microservice

This microservice provides a secure way to store and retrieve sensitive configuration values using Cumulocity Tenant Options (encrypted).
It is designed to work seamlessly with ThinEdge plugins by exposing simple REST endpoints for accessing encrypted configuration data.

## REST APIs

The complete API documentation is available here:
[Config Management API Documentation](../config/config-management-api-doc.json)

## Build Requirements

This microservice can be built using Maven, Java, and Docker.

### Prerequisites:
```text
Maven: 3.6 or higher
Java: 21 or higher
Docker: 26 or higher
```
```cmd 
Build Command
mvn clean install
```
## Deployment

Once built, the generated ZIP file can be deployed to a Cumulocity Management or Enterprise tenant using the:

[Microservice Deployment Tool](https://cumulocity.com/docs/microservice-sdk/general-aspects/#microservice-utility-tool)

Follow the standard microservice deployment steps provided by Cumulocity.

## Contribution Guidelines

Contributions are welcome!
Please follow the standard pull request workflow and ensure that all changes are adequately tested before submission.