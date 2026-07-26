use serde::{Deserialize, Deserializer, Serialize, Serializer};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DeviceType {
    Mobile,
    Desktop,
    Web,
    Headless,
    Server,
}

impl Serialize for DeviceType {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let value = match self {
            DeviceType::Mobile => "MOBILE",
            DeviceType::Desktop => "DESKTOP",
            DeviceType::Web => "WEB",
            DeviceType::Headless => "HEADLESS",
            DeviceType::Server => "SERVER",
        };
        serializer.serialize_str(value)
    }
}

impl<'de> Deserialize<'de> for DeviceType {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        match value.to_ascii_lowercase().as_str() {
            "mobile" => Ok(DeviceType::Mobile),
            "desktop" => Ok(DeviceType::Desktop),
            "web" => Ok(DeviceType::Web),
            "headless" => Ok(DeviceType::Headless),
            "server" => Ok(DeviceType::Server),
            _ => Err(serde::de::Error::unknown_variant(
                &value,
                &["mobile", "desktop", "web", "headless", "server"],
            )),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_type_deserializes_lowercase() {
        assert_eq!(
            serde_json::from_str::<DeviceType>("\"desktop\"").unwrap(),
            DeviceType::Desktop
        );
        assert_eq!(
            serde_json::from_str::<DeviceType>("\"mobile\"").unwrap(),
            DeviceType::Mobile
        );
    }

    #[test]
    fn device_type_deserializes_uppercase() {
        assert_eq!(
            serde_json::from_str::<DeviceType>("\"DESKTOP\"").unwrap(),
            DeviceType::Desktop
        );
        assert_eq!(
            serde_json::from_str::<DeviceType>("\"MOBILE\"").unwrap(),
            DeviceType::Mobile
        );
    }

    #[test]
    fn device_type_serializes_uppercase() {
        assert_eq!(
            serde_json::to_string(&DeviceType::Desktop).unwrap(),
            "\"DESKTOP\""
        );
    }
}
