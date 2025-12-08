package cumulocity.microservice.config.model;

import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.NoArgsConstructor;

@Data
@AllArgsConstructor
@NoArgsConstructor
public class ConfigMessage {
    private String category;
    private String key;
    private String value;
}
