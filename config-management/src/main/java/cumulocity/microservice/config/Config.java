package cumulocity.microservice.config;

import com.cumulocity.microservice.autoconfigure.MicroserviceApplication;

import org.springframework.boot.SpringApplication;

@MicroserviceApplication
public class Config {
    public static void main (String[] args) {
        SpringApplication.run(Config.class, args);
    }
}