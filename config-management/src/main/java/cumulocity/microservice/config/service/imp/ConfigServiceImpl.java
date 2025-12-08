package cumulocity.microservice.config.service.imp;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.stereotype.Service;

import com.cumulocity.microservice.subscription.service.MicroserviceSubscriptionsService;
import com.cumulocity.model.option.OptionPK;
import com.cumulocity.rest.representation.tenant.OptionRepresentation;
import com.cumulocity.sdk.client.option.TenantOptionApi;

import cumulocity.microservice.config.model.ConfigMessage;
import cumulocity.microservice.config.service.ConfigService;
import lombok.AllArgsConstructor;
import lombok.extern.slf4j.Slf4j;

@Slf4j
@Service
@AllArgsConstructor
public class ConfigServiceImpl implements ConfigService{

    private MicroserviceSubscriptionsService microserviceSubscriptionsService;
    private TenantOptionApi tenantOptionApi;

    public ResponseEntity<String> getConfig(String category, String key) {
        log.info("customer: {}, {}, tenant: {}",category, key, microserviceSubscriptionsService.getTenant());
        return microserviceSubscriptionsService.callForTenant(
            microserviceSubscriptionsService.getTenant(),
            () -> {
                try{
                    OptionPK pk = new OptionPK();
                    pk.setCategory(category);
                    pk.setKey(key);
                    OptionRepresentation options = tenantOptionApi.getOption(pk);               
                    return ResponseEntity.ok(options.getValue());
                }catch(Exception e){
                    log.error("key not found: {}", e.getMessage());
                    return ResponseEntity.status(HttpStatus.NOT_FOUND).body(e.getMessage());
                }
            }
        );
    }

    @Override
    public ResponseEntity<String> saveConfig(ConfigMessage config) {
       String res = microserviceSubscriptionsService.callForTenant(
            microserviceSubscriptionsService.getTenant(),
            () -> {
                OptionRepresentation or = new OptionRepresentation();
                or.setCategory(config.getCategory());
                or.setKey(config.getKey());
                or.setValue(config.getValue());
                OptionRepresentation options = tenantOptionApi.save(or);              
                return options.toJSON();
            }
        );
    
        return ResponseEntity.ok(res);
    }

    @Override
    public ResponseEntity<String> deleteConfig(String category, String key) {
        String res = microserviceSubscriptionsService.callForTenant(
            microserviceSubscriptionsService.getTenant(),
            () -> {
                OptionPK pk = new OptionPK();
                pk.setCategory(category);
                pk.setKey(key);
                tenantOptionApi.delete(pk);               
                return "Success";
            }
        );
    
        return ResponseEntity.ok(res);
    }
}    
