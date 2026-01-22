test
```mermaid
flowchart TB
    subgraph Internal["Internal Query (LAN)"]
        A1[app.example.com] --> B1[10.0.0.100]
        B1 --> C1[Direct to reverse proxy]
    end
    subgraph External["External Query (Internet)"]
        A2[app.example.com] --> B2[203.0.113.50]
        B2 --> C2[Public IP or tunnel]
    end
    
