package cumulocity.microservice.config.service;

import org.springframework.http.ResponseEntity;

import cumulocity.microservice.config.model.ConfigMessage;

public interface ConfigService {
    ResponseEntity<String> getConfig(String category, String key);
    ResponseEntity<String> saveConfig(ConfigMessage config);
    ResponseEntity<String> deleteConfig(String category, String key);
}
