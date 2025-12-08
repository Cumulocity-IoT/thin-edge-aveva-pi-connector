package cumulocity.microservice.config.controller;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.RestController;

import cumulocity.microservice.config.model.ConfigMessage;
import cumulocity.microservice.config.service.ConfigService;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;

import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;



@Slf4j
@RestController
@RequiredArgsConstructor
public class ConfigController {

    private final ConfigService configService;

    @GetMapping("/config")
    public ResponseEntity<String> getConfig(@RequestParam("category") String category, @RequestParam("key") String key) {
        log.info("Query Params: Category: {}, Key: {}",category, key);
        return configService.getConfig(category, key);
    }

    @PostMapping("/config")
    public ResponseEntity<String> postConfig(@RequestBody ConfigMessage config) {
        return configService.saveConfig(config);
    }

    @DeleteMapping("/config")
    public ResponseEntity<String> deleteConfig(@RequestParam("category") String category, @RequestParam("key") String key) {
        log.info("Query Params: Category: {}, Key: {}",category, key);
        return configService.deleteConfig(category, key);
    }
}

